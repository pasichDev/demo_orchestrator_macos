package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type InfoResponse struct {
	Message     string `json:"message"`
	Timestamp   string `json:"timestamp"`
	RandomValue int    `json:"random_value"`
}

func main() {
	port := flag.String("port", "8383", "port to listen on")
	flag.Parse()

	logger := log.New(os.Stdout, "[Backend] ", log.LstdFlags)

	mux := http.NewServeMux()

	mux.HandleFunc("/info", func(w http.ResponseWriter, r *http.Request) {
		logger.Printf("Request: GET /info from %s", r.RemoteAddr)

		response := InfoResponse{
			Message:     "Metric Synchronization Successful",
			Timestamp:   time.Now().Format(time.RFC3339),
			RandomValue: rand.Intn(100),
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)
	})

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "OK")
	})

	server := &http.Server{
		Addr:    ":" + *port,
		Handler: mux,
	}

	// Graceful shutdown orchestration
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	go func() {
		logger.Printf("Starting service on port %s", *port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Fatalf("Critical failure: %v", err)
		}
	}()

	<-stop
	logger.Println("Initiating graceful shutdown...")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		logger.Fatalf("Service shutdown failed: %v", err)
	}

	logger.Println("Service layer cleanly terminated.")
}
