require 'test_helper'
require 'dummy_puma'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusCollectorTest < Minitest::Test

  def setup
    PrometheusExporter::Metric::Base.default_prefix = ''
  end

  class PipedClient
    def initialize(collector, custom_labels: nil)
      @collector = collector
      @custom_labels = custom_labels
    end

    def send_json(obj)
      payload = obj.merge(custom_labels: @custom_labels).to_json
      @collector.process(payload)
    end
  end

  def test_register_metric
    collector = PrometheusExporter::Server::Collector.new
    metric = PrometheusExporter::Metric::Gauge.new("amazing", "amount of amazing")
    collector.register_metric(metric)
    metric.observe(77)
    metric.observe(2, red: "alert")
    text = <<~TXT
      # HELP amazing amount of amazing
      # TYPE amazing gauge
      amazing 77
      amazing{red="alert"} 2
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_collect_sidekiq_metrics
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector)

    instrument = PrometheusExporter::Instrumentation::Sidekiq.new(client: client)

    instrument.call("hello", nil, "default") do
      # nothing
    end

    begin
      instrument.call(false, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?("sidekiq_failed_jobs_total{job_name=\"FalseClass\"} 1"), "has failed job")

    assert(result.include?("sidekiq_jobs_total{job_name=\"String\"} 1"), "has working job")
    assert(result.include?("sidekiq_job_duration_seconds"), "has duration")
  end

  def test_it_can_collect_sidekiq_metrics_with_custom_labels
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    instrument = PrometheusExporter::Instrumentation::Sidekiq.new(client: client)

    instrument.call("hello", nil, "default") do
      # nothing
    end

    begin
      instrument.call(false, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?('sidekiq_failed_jobs_total{job_name="FalseClass",service="service1"} 1'), "has failed job")
    assert(result.include?('sidekiq_jobs_total{job_name="String",service="service1"} 1'), "has working job")
    assert(result.include?('sidekiq_job_duration_seconds{job_name="FalseClass",service="service1"}'), "has duration")
  end

  def test_it_can_collect_process_metrics
    # make some mini racer data
    ctx = MiniRacer::Context.new
    ctx.eval("1")

    collector = PrometheusExporter::Server::Collector.new

    process_instrumentation = PrometheusExporter::Instrumentation::Process.new(:web)
    collected = process_instrumentation.collect

    collector.process(collected.to_json)

    text = collector.prometheus_metrics_text

    v8_str = "v8_heap_count{pid=\"#{collected[:pid]}\",type=\"web\"} #{collected[:v8_heap_count]}"
    assert(text.include?(v8_str), "must include v8 metric")
    assert(text.include?("minor_gc_ops_total"), "must include counters")
  end

  def test_it_can_collect_delayed_job_metrics
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector)

    instrument = PrometheusExporter::Instrumentation::DelayedJob.new(client: client)

    job = Minitest::Mock.new
    job.expect(:handler, "job_class: Class")

    instrument.call(job, nil, "default") do
      # nothing
    end

    failed_job = Minitest::Mock.new
    failed_job.expect(:handler, "job_class: Object")

    begin
      instrument.call(failed_job, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?("delayed_failed_jobs_total{job_name=\"Object\"} 1"), "has failed job")
    assert(result.include?("delayed_jobs_total{job_name=\"Class\"} 1"), "has working job")
    assert(result.include?("delayed_job_duration_seconds"), "has duration")
    job.verify
    failed_job.verify
  end

  def test_it_can_collect_delayed_job_metrics_with_custom_labels
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    instrument = PrometheusExporter::Instrumentation::DelayedJob.new(client: client)

    job = Minitest::Mock.new
    job.expect(:handler, "job_class: Class")

    instrument.call(job, nil, "default") do
      # nothing
    end

    failed_job = Minitest::Mock.new
    failed_job.expect(:handler, "job_class: Object")

    begin
      instrument.call(failed_job, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?('delayed_failed_jobs_total{job_name="Object",service="service1"} 1'), "has failed job")
    assert(result.include?('delayed_jobs_total{job_name="Class",service="service1"} 1'), "has working job")
    assert(result.include?('delayed_job_duration_seconds{job_name="Class",service="service1"}'), "has duration")
    job.verify
    failed_job.verify
  end

  def test_it_can_collect_puma_single_metrics
    collector = PrometheusExporter::Server::Collector.new

    instrumentation = PrometheusExporter::Instrumentation::PumaStats.new

    collected = ''

    Puma.stub(:stats, '{"running":3,"backlog":4,"pool_capacity":0,"max_threads":3}') do
      collected = instrumentation.collect
    end

    collector.process(collected.to_json)

    text = collector.prometheus_metrics_text

    assert(text.include?('puma_worker_running_count{index="0",pid="-1"} 3'), 'has running threads')
    assert(text.include?('puma_worker_backlog_count{index="0",pid="-1"} 4'), 'has backlog')
    assert(text.include?('puma_worker_max_threads_count{index="0",pid="-1"} 3'), 'has max threads')
    assert(text.include?('puma_worker_pool_capacity{index="0",pid="-1"} 0'), 'has pool capacity')
  end

  def test_it_can_collect_puma_cluster_metrics
    collector = PrometheusExporter::Server::Collector.new

    instrumentation = PrometheusExporter::Instrumentation::PumaStats.new

    collected = ''

    puma_stats = JSON.dump({
      workers: 2,
      old_workers: 0,
      booted_workers: 2,
      phase: 3,
      worker_status: ([10,11].map.with_index do |pid, index|
        {
          pid: pid,
          index: index,
          phase: 3,
          booted: true,
          last_checkin: Time.now.iso8601,
          last_status: {
            running: 4,
            backlog: 1,
            max_threads: 4,
            pool_capacity: 0
          }
        }
      end)
    })

    Puma.stub(:stats, puma_stats) do
      collected = instrumentation.collect
    end

    collector.process(collected.to_json)

    text = collector.prometheus_metrics_text

    [10,11].each.with_index do |pid, index|
      assert(text.include?("puma_worker_running_count{index=\"#{index}\",pid=\"#{pid}\"} 4"), "has running threads for worker #{index}")
      assert(text.include?("puma_worker_backlog_count{index=\"#{index}\",pid=\"#{pid}\"} 1"), "has backlog for worker #{index}")
      assert(text.include?("puma_worker_max_threads_count{index=\"#{index}\",pid=\"#{pid}\"} 4"), "has max_threads for worker #{index}")
      assert(text.include?("puma_worker_pool_capacity{index=\"#{index}\",pid=\"#{pid}\"} 0"), "has pool capacity for worker #{index}")
    end

    assert(text.include?("puma_cluster_workers_count 2"), 'has worker count')
    assert(text.include?("puma_cluster_booted_count 2"), 'has booted count')
    assert(text.include?("puma_cluster_old_count 0"), 'has old count')
  end

end
