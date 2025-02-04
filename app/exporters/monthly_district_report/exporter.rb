module MonthlyDistrictReport
  class Exporter
    attr_reader :repo, :district, :month

    def initialize(district, period_month)
      @district = district
      @month = period_month
      @repo = Reports::Repository.new(district.facility_regions, periods: period_month)
    end

    def export
      facility_data = FacilityData.new(district, month)
      facility_csv = to_csv(facility_data.header_rows, facility_data.content_rows)

      block_data = BlockData.new(district, month)
      block_csv = to_csv(block_data.header_rows, block_data.content_rows)

      district_data = DistrictData.new(district, month)
      district_csv = to_csv(district_data.header_rows, district_data.content_rows)

      zip(facility_csv, block_csv, district_csv)
    end

    def zip(facility_csv, block_csv, district_csv)
      compressed_filestream = Zip::OutputStream.write_buffer(::StringIO.new("")) do |zos|
        zos.put_next_entry "facility_data.csv"
        zos.print facility_csv
        zos.put_next_entry "block_data.csv"
        zos.print block_csv
        zos.put_next_entry "district_data.csv"
        zos.print district_csv
      end
      compressed_filestream.rewind
      compressed_filestream.read
    end

    def to_csv(header_rows, content_rows)
      CSV.generate(headers: true) do |csv|
        csv << [nil]

        header_rows.each do |row|
          csv << row.prepend(nil)
        end

        content_rows.each do |row|
          csv << row.values.prepend(nil)
        end
      end
    end
  end
end
