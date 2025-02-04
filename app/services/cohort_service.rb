class CohortService
  include BustCache
  CACHE_VERSION = 3
  CACHE_TTL = 7.days

  attr_reader :field_prefix
  attr_reader :periods
  attr_reader :region
  attr_reader :region_field

  COUNTS = %i[
    cohort_controlled
    cohort_missed_visit
    cohort_patients
    cohort_uncontrolled
  ].freeze

  def initialize(region:, periods:)
    @region = region.region
    @periods = periods.sort.reverse # Ensure we return data with most recent cohorts first
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
    results = query(periods)
    compute(results)
  end

  private

  def compute(results)
    results.each_with_object([]) do |result, arry|
      registration_period = if quarterly?
        result.period.previous
      else
        result.period.advance(months: -2)
      end
      arry << {
        controlled: result.cohort_controlled,
        no_bp: result.cohort_missed_visit,
        period: result.period,
        patients_registered: registration_period.to_s,
        registered: result.cohort_patients,
        results_in: result.period.to_s(:cohort),
        uncontrolled: result.cohort_uncontrolled
      }.with_indifferent_access
    end
  end

  def query(range)
    if quarterly?
      range = range.map { |p| p.to_s(:quarter_string) }
      Reports::QuarterlyFacilityState.where(facility: region.facilities, quarter_string: range)
        .group(region_field, :quarter_string, :month_date)
        .order("quarter_string desc")
        .select(:month_date, region_field, sums)
    else
      range = periods.map { |p| p.value }
      Reports::FacilityState.where(facility: region.facilities, month_date: range)
        .group(region_field, :month_date)
        .order("month_date desc")
        .select(:month_date, region_field, sums)
    end
  end

  def cache_key(period)
    "#{self.class}/#{region.cache_key}/#{period.cache_key}"
  end

  def cache_version
    "#{region.updated_at.utc.to_s(:usec)}/#{CACHE_VERSION}"
  end
end
