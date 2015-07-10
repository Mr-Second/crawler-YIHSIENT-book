require 'crawler_rocks'
require 'pry'
require 'iconv'
require 'isbn'
require 'json'

require 'thread'
require 'thwait'

class YihsientBookCrawler
  include CrawlerRocks::DSL

  def initialize
    @query_url = "http://www.yihsient.com.tw/front/bin/ptsearch.phtml"
    @detail_url = "http://www.yihsient.com.tw/front/bin/ptdetail.phtml"
    @ic = Iconv.new("utf-8//translit//IGNORE","big5")
  end

  def books
    @books = []
    @threads = []

    r = RestClient.get @query_url
    @doc = Nokogiri::HTML(@ic.iconv r)

    book_count = @doc.xpath('//td[@class="ptsearch-heading"]/following-sibling::td').text.match(/(?<=總共  )\d+/).to_s.to_i
    done_book_count = 0

    page_num = book_count / 20 + 1
    page_num.times do |i|
      print "page: #{i}\n"

      @doc.css('.pt-tblist-tb tr:not(:first-child)').each_with_index do |row, row_i|
        sleep(1) until (
          @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
          @threads.count < (ENV['MAX_THREADS'] || 10)
        )
        @threads << Thread.new do
          datas = row.css('td')

          internal_code = datas[1] && datas[1].text.strip
          url = "#{@detail_url}?Part=#{internal_code}"

          r = RestClient.get url
          doc = Nokogiri::HTML(@ic.iconv r)

          external_image_url = doc.css('img').map{|img| img[:src]}.find{|src| src.include?(internal_code)}
          if external_image_url.nil?
            if @tired
              @tired = false
            else
              @tired = true
              sleep 2
              redo
            end
          end

          pairs = []
          doc.css('.ptdet-def-table tr').each{|tr| pairs.concat tr.text.strip.split(/\n\t\t  \n\t\t  \n\t\t    \n\t\t/) }
          publisher = nil; edition = nil; isbn_13 = nil; isbn_10 = nil;
          author = nil;
          pairs.map {|pp| pp.gsub(/\s+/, ' ').strip }.each do |attribute|
            attribute.match(/發行公司 : (.+)/) {|m| publisher ||= m[1]}
            attribute.match(/版次 : (.+)/) {|m| edition ||= m[1]}
            attribute.match(/ISBN-13碼 :(.+)/) {|m| isbn_13 ||= m[1].strip }
            attribute.match(/ISBN-10碼 :(.+)/) {|m| isbn_10 ||= m[1].strip }

            attribute.match(/作者 : (.+)/) {|m| author ||= m[1].strip if not m[1].strip.empty? }
            attribute.match(/原著 : (.+)/) {|m| author ||= m[1].strip if not m[1].strip.empty? }
            attribute.match(/譯者 : (.+)/) {|m| author ||= m[1].strip if not m[1].strip.empty? }
          end

          isbn = isbn_13 || ISBN.thirteen(isbn_10)

          edition = nil if edition = 0

          @books << {
            name: datas[2] && datas[2].text.strip,
            author: author,
            edition: edition.to_i,
            price: datas[8] && datas[8].text.gsub(/[^\d]/, '').to_i,
            internal_code: internal_code,
            url: url,
            isbn: isbn,
            external_image_url: external_image_url,
            publisher: publisher,
          }

          done_book_count += 1
          print "#{done_book_count} / #{book_count}\n"
        end # end Thread do
      end # end each row

      r = RestClient.get @query_url, get_view_state.merge({"GoTo" => 'Next'})
      @doc = Nokogiri::HTML(@ic.iconv r)
    end
    ThreadsWait.all_waits(*@threads)

    @books
  end
end

cc = YihsientBookCrawler.new
File.write('yihsient_books.json', JSON.pretty_generate(cc.books))
