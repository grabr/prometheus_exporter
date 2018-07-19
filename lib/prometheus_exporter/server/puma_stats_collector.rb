module PrometheusExporter::Server
  class PumaStatsCollector < TypeCollector
    PUMA_CLUSTER_GAUGES = {
      'puma_cluster_workers_count' => 'Configured workers count',
      'puma_cluster_old_count' => 'Old workers count',
      'puma_cluster_booted_count' => 'Booted workers count',
    }

    PUMA_WORKER_GAUGES = {
      'puma_worker_backlog_count' => 'Backlog size',
      'puma_worker_running_count' => 'Active threads count',
      'puma_worker_max_threads_count' => 'Configured max threads count',
      'puma_worker_pool_capacity' => 'Negative backpressure.'
    }

    def initialize
      @puma_metrics = {}
    end

    def type
      'puma'
    end

    def collect(stats)
      # if this is not nil we assume that Puma is running in cluster mode
      if stats['puma_cluster_workers_count']
        collect_cluster_metrics(stats)
      else
        collect_worker_metrics(stats)
      end
    end

    def metrics
      @puma_metrics.values
    end

    protected

    def collect_cluster_metrics(stats)
      PUMA_CLUSTER_GAUGES.keys.each do |name, hint|
        if val = stats[name]
          gauge = @puma_metrics[name] ||= PrometheusExporter::Metric::Gauge.new(name, hint)
          gauge.observe val
        end
      end

      if workers = stats['workers_stats']
        workers.each do |w|
          collect_worker_metrics(w)
        end
      end
    end

    def collect_worker_metrics(stats)
      label = {
        'index' => (stats['index'] || 0),
        'pid' => (stats['pid'] || -1)
       }

      PUMA_WORKER_GAUGES.keys.each do |name, hint|
        if val = stats[name]
          gauge = @puma_metrics[name] ||= PrometheusExporter::Metric::Gauge.new(name, hint)
          gauge.observe val, label
        end
      end
    end
  end
end
