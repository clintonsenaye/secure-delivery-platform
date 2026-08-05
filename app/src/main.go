// A deliberately small HTTP service.
//
// It exists so the platform around it has something real to deliver. It is
// boring on purpose: the platform is the portfolio, not the application. There
// is no database, no framework and no configuration file. Everything it needs
// arrives as an environment variable set by the Deployment manifest in Git.
//
// Four endpoints:
//
//	/          a greeting, the version, and the pod serving it
//	/healthz   liveness and readiness
//	/version   provenance: what commit built this binary, and what it hashes to
//	/metrics   Prometheus exposition
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Injected at link time by the Dockerfile with -ldflags -X. The defaults are
// deliberately ugly so that a binary built outside the documented build path
// announces itself as such rather than quietly claiming to be a real release.
var (
	version   = "dev"
	gitCommit = "unknown"
	buildTime = "unknown"
)

var (
	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "demo_app_http_requests_total",
		Help: "Total HTTP requests, by path, method and response status.",
	}, []string{"path", "method", "status"})

	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "demo_app_http_request_duration_seconds",
		Help:    "HTTP request duration in seconds, by path.",
		Buckets: prometheus.DefBuckets,
	}, []string{"path"})

	buildInfo = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "demo_app_build_info",
		Help: "Build provenance as labels. The value is always 1.",
	}, []string{"version", "git_commit", "build_time"})
)

// binarySHA256 hashes the running executable through /proc/self/exe.
//
// This is the one provenance claim the application can make entirely on its
// own, without trusting an environment variable that something else set. In
// chapter 3 it becomes checkable: the signature covers the image, the image
// contains this binary, and this is the binary's digest as computed by the
// binary itself while running.
//
// Computed once, lazily, because hashing a few megabytes on every request would
// be silly.
var binarySHA256 = sync.OnceValue(func() string {
	f, err := os.Open("/proc/self/exe")
	if err != nil {
		return "unavailable: " + err.Error()
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "unavailable: " + err.Error()
	}
	return "sha256:" + hex.EncodeToString(h.Sum(nil))
})

// env reads an environment variable, falling back to a default. Every value the
// service needs comes through here, which means every value is visible in the
// Deployment manifest in Git rather than baked into the image.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// instrument wraps a handler so every response is counted and timed. It records
// the status code, which needs a small ResponseWriter wrapper because the
// standard one does not expose what was written.
func instrument(path string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		next(rec, r)

		httpDuration.WithLabelValues(path).Observe(time.Since(start).Seconds())
		httpRequests.WithLabelValues(path, r.Method, strconv.Itoa(rec.status)).Inc()
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	var (
		addr     = ":" + env("PORT", "8080")
		greeting = env("GREETING", "hello")
		podName  = env("POD_NAME", "unknown")
		nodeName = env("NODE_NAME", "unknown")
		podNS    = env("POD_NAMESPACE", "unknown")
	)

	buildInfo.WithLabelValues(version, gitCommit, buildTime).Set(1)

	mux := http.NewServeMux()

	// The pod name is on the greeting deliberately. It is what makes the
	// self-healing demonstration visible: delete the Deployment, and the name
	// on this page changes when ArgoCD rebuilds it from Git.
	mux.HandleFunc("/", instrument("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintf(w, "%s\n\nversion %s\ncommit  %s\npod     %s\nnode    %s\n",
			greeting, version, gitCommit, podName, nodeName)
	}))

	mux.HandleFunc("/healthz", instrument("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintln(w, "ok")
	}))

	// Provenance. In chapter 2 image_digest is honest about being unset,
	// because the image is side-loaded into kind rather than pulled by digest
	// from a registry. Chapter 3 sets IMAGE_DIGEST to the digest that was
	// actually signed, and this endpoint becomes the visible proof that what is
	// running is what was verified at admission.
	mux.HandleFunc("/version", instrument("/version", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		_ = enc.Encode(map[string]string{
			"version":       version,
			"git_commit":    gitCommit,
			"build_time":    buildTime,
			"binary_sha256": binarySHA256(),
			"image":         env("IMAGE_REF", "unset"),
			"image_digest":  env("IMAGE_DIGEST", "unset: chapter 2 side-loads the image into kind, see docs/architecture.md"),
			"pod":           podName,
			"namespace":     podNS,
			"node":          nodeName,
		})
	}))

	// Not instrumented. Scraping the metrics endpoint should not itself move
	// the metrics, or every scrape changes what the next scrape reports.
	mux.Handle("/metrics", promhttp.Handler())

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Graceful shutdown. Kubernetes sends SIGTERM and then waits out the
	// termination grace period before SIGKILL. Draining in that window is what
	// stops a rolling update from dropping in-flight requests, which matters
	// here because both demonstrations roll the pods on camera.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		log.Info("listening",
			"addr", addr, "version", version, "commit", gitCommit, "pod", podName)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	<-stop
	log.Info("shutting down")

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Error("shutdown failed", "error", err)
		os.Exit(1)
	}
	log.Info("stopped")
}
