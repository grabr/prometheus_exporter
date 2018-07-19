module PrometheusExporter::Instrumentation
  class PumaStats
    def self.start(client: nil, frequency: 3, puma_startup_timeout: 10)
      collector = self.new
      client ||= PrometheusExporter::Client.default

      Thread.new do
        # wait til server started and Puma.stats object is available
        sleep puma_startup_timeout

        loop do
          begin
            metric = collector.collect
            client.send_json metric
          rescue => e
            STDERR.puts("Puma Collector Failed To Collect Stats #{e}")
          end

          sleep(frequency)
        end
      end
    end

    def collect
      stats = JSON.parse(Puma.stats)

      metrics =
        if stats['workers']
          collect_for_clustered(stats)
        else
          collect_for_single(stats)
        end

      metrics.merge type: 'puma'
    end

    private

    def collect_for_clustered(stats)
      metrics = {}
      metrics[:puma_cluster_workers_count] = stats['workers']
      metrics[:puma_cluster_booted_count] = stats['booted_workers']
      metrics[:puma_cluster_old_count] = stats['old_workers']
      metrics[:workers_stats] = []

      stats['worker_status'].each do |w|
        m = { pid: w['pid'], index: w['index'] }
        m.merge!(collect_for_single(w['last_status']))

        metrics[:workers_stats] << m
      end

      metrics
    end

    def collect_for_single(stats)
      {
        puma_worker_backlog_count: stats['backlog'],
        puma_worker_running_count: stats['running'],
        puma_worker_max_threads_count: stats['max_threads'],
        puma_worker_pool_capacity: stats['pool_capacity']
      }
    end
  end
end
