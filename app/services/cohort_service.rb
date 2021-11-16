class CohortService
  include BustCache
  CACHE_VERSION = 3
  CACHE_TTL = 7.days

  attr_reader :field_prefix
  attr_reader :periods
  attr_reader :region
  attr_reader :region_field
  attr_reader :reporting_schema_v2

  COUNTS = %i[
    cohort_controlled
    cohort_missed_visit
    cohort_patients
    cohort_uncontrolled
  ].freeze

  def initialize(region:, periods:, reporting_schema_v2: Reports.reporting_schema_v2?)
    @region = region.region
    @periods = periods
    @reporting_schema_v2 = reporting_schema_v2
    @region_field = "#{@region.region_type}_region_id"
    @quarterly = @periods.first.quarter?
    @field_prefix = quarterly? ? "quarterly" : "monthly"
  end

  def quarterly?
    @quarterly
  end

  def sums
    @sums ||= COUNTS.map { |field| Arel.sql("SUM(#{field_prefix}_#{field}::int) as #{field}") }
  end

  def call
    if reporting_schema_v2
      # For monthly cohorts, we have to select the month_string that results are gathered in -
      # so we add two months onto the range for that case.
      range = quarterly? ? periods : periods.map { |p| p.advance(months: 2) }
      results = v2_query(range)
      compute_v2(results, range)
    else
      periods.each_with_object([]) do |period, arry|
        arry << compute(period)
      end
    end
  end

  private

  def compute_v2(results, range)
    range.each_with_object([]).with_index do |(period, arry), i|
      if quarterly?
        cohort_period = period.previous
        results_in = period.to_s
      else
        cohort_period = period.advance(months: -2)
        results_in = period.to_s(:cohort)
      end
      stat = results[i]
      arry << {
        controlled: stat.cohort_controlled,
        no_bp: stat.cohort_missed_visit,
        patients_registered: cohort_period.to_s,
        registered: stat.cohort_patients,
        results_in: results_in,
        uncontrolled: stat.cohort_uncontrolled
      }.with_indifferent_access
    end
  end

  def v2_query(range)
    if quarterly?
      range = range.map { |p| p.to_s(:quarter_string) }
      Reports::QuarterlyFacilityState.where(facility: region.facilities, quarter_string: range)
        .group(region_field, :quarter_string)
        .select(:quarter_string, region_field, sums)
    else
      Reports::FacilityState.where(facility: region.facilities, month_date: range)
        .group(region_field, :month_date)
        .select(:month_date, region_field, sums)
    end
  end

  def compute(period)
    Rails.cache.fetch(cache_key(period), version: cache_version, expires_in: CACHE_TTL, force: bust_cache?) do
      cohort_period = period.previous
      results_in = if period.quarter?
        period.to_s
      else
        [period, period.next].map { |p| p.value.strftime("%b") }.join("/")
      end
      hsh = {cohort_period: cohort_period.type,
             registration_quarter: cohort_period.value.try(:number),
             registration_year: cohort_period.value.try(:year),
             registration_month: cohort_period.value.try(:month)}
      query = ControlRateCohortQuery.new(facilities: region.facilities, cohort_period: hsh)
      {
        results_in: results_in,
        patients_registered: cohort_period.to_s,
        registered: query.cohort_patients.count,
        controlled: query.cohort_controlled_bps.count,
        no_bp: query.cohort_missed_visits_count,
        uncontrolled: query.cohort_uncontrolled_bps.count
      }.with_indifferent_access
    end
  end

  def default_range
    Quarter.new(date: Date.current).downto(3)
  end

  def cache_key(period)
    "#{self.class}/#{region.cache_key}/#{period.cache_key}"
  end

  def cache_version
    "#{region.updated_at.utc.to_s(:usec)}/#{CACHE_VERSION}"
  end
end
