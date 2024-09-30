# frozen_string_literal: true

require 'http_utils'
require 'iiif_base'

module IIIF
  module Fedora2
    # Fedora 2 resource
    class Item < IIIF::Item # rubocop:disable Metrics/ClassLength
      include HttpUtils

      PREFIX = 'fedora2'
      CONFIG = IIIF_CONFIG[PREFIX]
      METS_NAMESPACE = 'http://www.loc.gov/METS/'

      def image_base_uri
        CONFIG['image_url']
      end

      attr_reader :query

      def initialize(path, query) # rubocop:disable Lint/MissingSuper
        @pid, @service = path.split(/_/, 2)
        @query = query
        @image_info_for = {}
      end

      def get_formatted_id(pid)
        "#{PREFIX}:#{pid}"
      end

      def base_uri
        "#{CONFIG['manifest_url']}#{PREFIX}:#{@pid}/"
      end

      def doc
        return @doc if @doc

        solr_query = @service ? "hasPart:\"#{@pid}\"" : "pid:\"#{@pid}\""
        # stuck on ruby 2.2 so no #dig :(
        @doc =
          begin
            get_solr_doc(solr_query)['response']['docs']
              .first.with_indifferent_access
          rescue NoMethodError
            nil
          end
      end

      def mets
        @mets ||= Nokogiri::XML(mets_xml)
      end

      def label
        if doc&.key?('displayTitle') && doc['displayTitle'].present?
          doc['displayTitle']
        else
          @pid
        end
      end

      def manifest_level?
        true
      end

      def canvas_level?
        false
      end

      def pages # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        if @service
          # only one page; @pid is the image PID
          canvas_label = label != @pid ? label : 'Image'
          [get_page(@pid, canvas_label)]
        else
          # see if we have this item and its assets indexed in the fedora4 core
          # if so, build a mapping from pids to image dimensions so we don't
          # have to request the image info.json for each one from IIIF
          params = {
            q: "identifier:#{@pid.gsub(':', '\\:')}",
            'pages.fq': 'rdf_type:pcdm\\:Object',
            'pages.fl': 'id,display_title,page_number,identifier',
            'pages.rows': 1000,
            'images.fq': 'rdf_type:pcdmuse\\:IntermediateFile',
            'images.rows': 1000,
            wt: :json
          }
          pcdm_solr_doc = http_get("#{CONFIG['fcrepo_solr_url']}pcdm", params).body

          if pcdm_solr_doc['response']['numFound'].positive?
            pid_for_uri = pcdm_solr_doc['response']['docs'][0]['pages']['docs'].map do |page|
              [page['id'], page['identifier'][0]]
            end.to_h
            images = pcdm_solr_doc['response']['docs'][0]['images']['docs']
            @image_info_for = images.map do |img|
              [pid_for_uri[img['pcdm_file_of']], { width: img['image_width'], height: img['image_height'] }]
            end.to_h
          end

          # look up the METS relations in Fedora 2 to get a list of image PIDs
          imgs = mets.xpath(
            '/mets:mets/mets:structMap[@TYPE="LOGICAL"]/mets:div[@ID="images"]/*[//mets:div[@ID="DISPLAY"]/mets:fptr]',
            mets: METS_NAMESPACE
          )

          imgs.each_with_index.map do |img, order|
            label = image_label_for img, order
            fptrs = img.xpath('.//mets:div[@ID="DISPLAY"]/mets:fptr', mets: METS_NAMESPACE)
            fptrs.map do |fptr|
              fileid = fptr.attribute('FILEID').value
              flocat = mets.at_xpath(
                '/mets:mets/mets:fileSec/mets:fileGrp/mets:file[@ID=$id]/mets:FLocat',
                { mets: METS_NAMESPACE },
                id: fileid
              )
              pid = flocat.attribute('href').value
              get_page(pid, label)
            end
          end.flatten
        end
      end

      def image_label_for(img, order)
        if img['LABEL']
          img['LABEL']
        elsif img['ORDER'] && img['ORDER'].strip =~ /^\d+$/
          "Page #{img['ORDER'].strip}"
        else
          "Page #{order + 1}"
        end
      end

      def get_solr_doc(query = '*:*')
        params = { q: query, wt: :json }
        JSON.parse(http_get("#{CONFIG['solr_url']}select", params).body)
      end

      def mets_xml
        http_get(CONFIG['fedora2_url'] + "fedora/get/#{@pid}/umd-bdef:rels-mets/getRels/").body
      end

      def get_page(pid, label)
        IIIF::Page.new.tap do |page|
          page.id = get_formatted_id(pid)
          page.label = label.empty? ? pid : label
          page.image = get_image(pid)
        end
      end

      def get_image_info(pid)
        @image_info_for[pid] ||= http_get("#{image_uri(pid)}/info.json").body
      end

      def get_image(pid)
        image_id = get_formatted_id(pid)
        info = get_image_info(image_id)
        return unavailable_image if info.blank?

        IIIF::Image.new.tap do |image|
          image.id = image_id
          image.width = info['width']
          image.height = info['height']
        end
      rescue *HTTP_ERRORS
        unavailable_image
      end

      def metadata
        return {} unless doc&.include?('dmDate')

        # in the future we'll probably wanna get md from here..
        # we'll leave it on ice for now.
        # desc =  Nokogiri::XML(doc["umdm"])
        doc['dmDate'].map do |date|
          { 'label': 'Date', 'value': Time.zone.parse(date).strftime('%Y-%m-%d') }
        end
      end
    end
  end
end
