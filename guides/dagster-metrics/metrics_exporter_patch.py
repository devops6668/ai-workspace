"""
Patch for metrics_exporter.py - Add job run duration metrics
Apply these changes to /luban_dagster_platform/metrics_exporter.py
"""

# ============================================================================
# NEW HELPER FUNCTIONS (add after _job_counts_15m function)
# ============================================================================

def _get_run_duration_seconds(record) -> float:
    """Calculate the duration of a completed run in seconds.
    
    Uses start_time and end_time from the RunRecord if available,
    otherwise falls back to create_timestamp and update_timestamp.
    """
    # Try start_time and end_time first (most accurate)
    start_time = getattr(record, 'start_time', None)
    end_time = getattr(record, 'end_time', None)
    
    if start_time is not None and end_time is not None:
        return max(0.0, end_time - start_time)
    
    # Fallback: use create_timestamp and update_timestamp
    create_ts = record.create_timestamp
    update_ts = record.update_timestamp
    
    if create_ts is not None and update_ts is not None:
        import calendar
        if hasattr(create_ts, 'timestamp'):
            create_epoch = create_ts.timestamp()
            update_epoch = update_ts.timestamp()
        else:
            create_epoch = calendar.timegm(create_ts.timetuple())
            update_epoch = calendar.timegm(update_ts.timetuple())
        
        return max(0.0, update_epoch - create_epoch)
    
    return 0.0


def _job_run_durations(instance: DagsterInstance, limit: int = 500) -> dict[str, tuple[float, float]]:
    """Return {pipeline_name: (last_duration_seconds, avg_duration_seconds)} for completed runs.
    
    Only includes SUCCESS and FAILURE runs (completed runs).
    """
    records = instance.get_run_records(
        RunsFilter(statuses=[DagsterRunStatus.SUCCESS, DagsterRunStatus.FAILURE]),
        limit=limit,
        order_by="create_timestamp",
        ascending=False,
    )
    
    durations: dict[str, list[float]] = {}
    
    for record in records:
        run = record.dagster_run
        pname = run.job_name or run.pipeline_name or "unknown"
        
        duration = _get_run_duration_seconds(record)
        if duration > 0:
            if pname not in durations:
                durations[pname] = []
            durations[pname].append(duration)
    
    result: dict[str, tuple[float, float]] = {}
    for pname, dur_list in durations.items():
        last_duration = dur_list[0] if dur_list else 0.0
        avg_duration = sum(dur_list) / len(dur_list) if dur_list else 0.0
        result[pname] = (last_duration, avg_duration)
    
    return result


def _job_run_durations_by_status(instance: DagsterInstance, limit: int = 500) -> dict[str, dict[str, float]]:
    """Return {pipeline_name: {status: avg_duration_seconds}} for completed runs.
    
    Groups duration by status (SUCCESS/FAILURE) to compare success vs failure times.
    """
    records = instance.get_run_records(
        RunsFilter(statuses=[DagsterRunStatus.SUCCESS, DagsterRunStatus.FAILURE]),
        limit=limit,
        order_by="create_timestamp",
        ascending=False,
    )
    
    durations: dict[str, dict[str, list[float]]] = {}
    
    for record in records:
        run = record.dagster_run
        pname = run.job_name or run.pipeline_name or "unknown"
        status = run.status.value  # type: ignore[attr-defined]
        
        duration = _get_run_duration_seconds(record)
        if duration > 0:
            if pname not in durations:
                durations[pname] = {}
            if status not in durations[pname]:
                durations[pname][status] = []
            durations[pname][status].append(duration)
    
    result: dict[str, dict[str, float]] = {}
    for pname, status_durs in durations.items():
        result[pname] = {}
        for status, dur_list in status_durs.items():
            result[pname][status] = sum(dur_list) / len(dur_list) if dur_list else 0.0
    
    return result


# ============================================================================
# NEW CALLBACK FUNCTIONS (add after job_queued_count_15m_cb)
# ============================================================================

def job_duration_cb(_options):
    """Duration of the last completed run per pipeline."""
    durations = _job_run_durations(instance)
    for pname, (last_dur, _avg_dur) in durations.items():
        yield Observation(last_dur, attributes={"dagster.pipeline_name": pname})


def job_avg_duration_cb(_options):
    """Average duration of completed runs in the last hour per pipeline."""
    durations = _job_run_durations(instance)
    for pname, (_last_dur, avg_dur) in durations.items():
        yield Observation(avg_dur, attributes={"dagster.pipeline_name": pname})


def job_duration_by_status_cb(_options):
    """Duration breakdown by status (success vs failure) per pipeline."""
    durations = _job_run_durations_by_status(instance)
    for pname, status_durs in durations.items():
        for status, avg_dur in status_durs.items():
            yield Observation(avg_dur, attributes={
                "dagster.pipeline_name": pname,
                "dagster.status": status
            })


# ============================================================================
# REGISTER NEW GAUGES (add after existing job-level gauges registration)
# ============================================================================

# Add these after the existing job-level gauges:

# Duration metrics
meter.create_observable_gauge("dagster.job.run.duration_seconds", callbacks=[job_duration_cb], unit="s")
meter.create_observable_gauge("dagster.job.run.avg_duration_seconds", callbacks=[job_avg_duration_cb], unit="s")
meter.create_observable_gauge("dagster.job.run.duration_by_status", callbacks=[job_duration_by_status_cb], unit="s")


# ============================================================================
# UPDATED _job_last_run_statuses (optional enhancement)
# ============================================================================

# If you want to include duration in the last_status metric, update the callback:

def job_last_status_cb_enhanced(_options):
    """Last run status with duration for each pipeline."""
    records = instance.get_run_records(
        RunsFilter(),
        limit=500,
        order_by="create_timestamp",
        ascending=False,
    )
    now = time.time()
    seen: dict[str, bool] = {}
    
    for record in records:
        run = record.dagster_run
        pname = run.job_name or run.pipeline_name or "unknown"
        
        if pname in seen:
            continue
        seen[pname] = True
        
        status_val = _STATUS_VALUE.get(run.status.value, -99)  # type: ignore[attr-defined]
        
        # Calculate age
        ts = record.create_timestamp
        age = 0.0
        if ts is not None:
            if ts.tzinfo is not None:
                ts_epoch = ts.timestamp()
            else:
                import calendar
                ts_epoch = calendar.timegm(ts.timetuple())
            age = max(0.0, now - ts_epoch)
        
        # Calculate duration (if run is completed)
        duration = _get_run_duration_seconds(record)
        
        yield Observation(status_val, attributes={
            "dagster.pipeline_name": pname,
            "dagster.age_seconds": str(age),
            "dagster.duration_seconds": str(duration)
        })
