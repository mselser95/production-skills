// Package jobs runs a list of jobs, one after another or on a worker pool.
package jobs

import (
	"context"
	"errors"
)

// ErrWorkers is returned when a pool is asked for fewer than one worker.
var ErrWorkers = errors.New("workers must be at least 1")

// Job is one unit of work. It should return promptly once ctx is cancelled.
type Job func(ctx context.Context) error

// Serial runs jobs in order and stops at the first error. If ctx is cancelled
// before every job has run, it returns ctx.Err().
func Serial(ctx context.Context, jobs []Job) error {
	for _, j := range jobs {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := j(ctx); err != nil {
			return err
		}
	}
	return nil
}
