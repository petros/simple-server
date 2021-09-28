# frozen_string_literal: true

class MyFacilitiesController < AdminController
  require "csv"
  include Pagination
  include MyFacilitiesFiltering
  include CohortPeriodSelection
  include PeriodSelection
  include ActionView::Helpers::NumberHelper #can use view_context.#method instead as well
  include DashboardHelper #same comment as above

  PERIODS_TO_DISPLAY = {quarter: 3, month: 3, day: 14}.freeze

  around_action :set_reporting_time_zone
  before_action :set_period, except: [:index]
  before_action :authorize_my_facilities
  before_action :set_selected_cohort_period, only: [:blood_pressure_control]
  before_action :set_selected_period, only: [:registrations, :missed_visits]
  before_action :set_last_updated_at

  def index
    @facilities = current_admin.accessible_facilities(:view_reports)
    users = current_admin.accessible_users(:manage)

    @users_requesting_approval = paginate(users
                                            .requested_sync_approval
                                            .order(updated_at: :desc))

    overview_query = OverviewQuery.new(facilities: @facilities)
    @inactive_facilities = overview_query.inactive_facilities

    @facility_counts_by_size = {total: @facilities.group(:facility_size).count,
                                inactive: @inactive_facilities.group(:facility_size).count}

    @inactive_facilities_bp_counts =
      {last_week: overview_query.total_bps_in_last_n_days(n: 7),
       last_month: overview_query.total_bps_in_last_n_days(n: 30)}
  end

  def bp_controlled
    process_facility_stats(:controlled_patients)
  end

  def bp_not_controlled
    process_facility_stats(:uncontrolled_patients)
  end

  def missed_visits
    process_facility_stats(:missed_visits)
  end
############################### -- URL to localhost:3000/my_facilities/csv_maker, I added a line in routes.rb for this method
  def csv_maker
    process_facility_stats(params[:type])
    send_data generate_csv(),  type: "text/csv"
  end

  def generate_csv() ### abstracted csv stuff to this code, will in order to be executed above
    return CSV.generate(){ |csv|
      # rate_name = "controlled_patients_rate" #1
      # rate_name = "uncontrolled_patients_rate"
      rate_name = "missed_visits_rate"

      headers = ["Facilities", "Total assigned", "Total registered","6-month change"]
      (@start_period..@period).each {|period| headers << period << "Ratio" } # Monthly percentage headers, Monthly ratio headers
      csv << headers

      @display_sizes.each_with_index do |size, i| #For loop for the top row/ Sites of that size
        row = []
        six_month_rate_change = facility_size_six_month_rate_change(@stats_by_size[size][:periods], rate_name)
        row << "All #{Facility.localized_facility_size(size)}s" # Facilities
        row << number_or_zero_with_delimiter(@stats_by_size[size][:periods][@period][:cumulative_assigned_patients]) #Assigned
        row << number_or_zero_with_delimiter(@stats_by_size[size][:periods][@period][:cumulative_registrations]) # Registered
        row <<  number_to_percentage(six_month_rate_change, precision: 0) #6 month change
        @stats_by_size[size][:periods].each_pair do |period, data| 
          controlled_patients_rate = data["controlled_patients_rate"]
          row << number_to_percentage(controlled_patients_rate || 0, precision: 0) #Monthly rate change
          row << "#{data["controlled_patients"]} / #{data["adjusted_patient_counts"]}" #Monthly ratio
        end
        csv << row
        @data_for_facility.each do |_, facility_data| #For loop for subsequent rows
          sub_row = []
          facility = facility_data.region.source
          next if facility.facility_size != size
          six_month_rate_change = six_month_rate_change(facility, "controlled_patients_rate")
          sub_row << facility.name # Facility name
          sub_row << number_or_zero_with_delimiter(facility_data["cumulative_assigned_patients"].values.last) # Assigned
          sub_row << number_or_zero_with_delimiter(facility_data["cumulative_registrations"].values.last) # Registered
          sub_row << number_to_percentage_with_symbol(six_month_rate_change, precision: 0) # 6 month change
          (@start_period..@period).each do |period|
            controlled_patients_rate = facility_data["controlled_patients_rate"][period] #redeclaring this variable for the inner loop we are using
            sub_row << number_to_percentage(controlled_patients_rate || 0, precision: 0) #Monthly rate
            sub_row << "#{facility_data["controlled_patients"][period]} / #{facility_data["adjusted_patient_counts"][period]}" #Monthly ratio
          end
          csv << sub_row
        end
        csv << [] if i != @display_sizes.length-1 #Partition between the facility sizes, for clarity
      end
    }
  end
##################################
  private

  def set_last_updated_at
    last_updated_at = RefreshReportingViews.last_updated_at
    @last_updated_at =
      if last_updated_at.nil?
        "unknown"
      else
        last_updated_at.in_time_zone(Rails.application.config.country[:time_zone]).strftime("%d-%^b-%Y %I:%M%p")
      end
  end

  def authorize_my_facilities
    authorize { current_admin.accessible_facilities(:view_reports).any? }
  end

  def set_period
    @period = Period.month(Date.current.last_month.beginning_of_month)
    @start_period = @period.advance(months: -5)
  end

  def report_params
    params.permit(:id, :bust_cache, :report_scope, {period: [:type, :value]})
  end

  def process_facility_stats(type)
    facilities = filter_facilities
    @data_for_facility = {}

    facilities.each do |facility|
      @data_for_facility[facility.name] = Reports::RegionService.new(
        region: facility.region, period: @period, months: 6
      ).call
    end
    sizes = @data_for_facility.map { |_, facility| facility.region.source.facility_size }.uniq
    @display_sizes = @facility_sizes.select { |size| sizes.include? size }
    @stats_by_size = FacilityStatsService.call(facilities: @data_for_facility, period: @period, rate_numerator: type)
  end
end
