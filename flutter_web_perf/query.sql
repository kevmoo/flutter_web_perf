WITH frame_times AS (
  SELECT ts,
         LEAD(ts) OVER (ORDER BY ts) - ts AS frame_dur
  FROM slice
  WHERE name = 'Scheduler::BeginFrame'
)
SELECT AVG(frame_dur) / 1000000.0 AS avg_frame_interval_ms
FROM frame_times
WHERE frame_dur IS NOT NULL;
