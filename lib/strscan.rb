# frozen_string_literal: true

require "strscan.so"

class StringScanner
  class Error < StandardError; end

  Object.const_set(:ScanError, Error)

  INSPECT_LENGTH = 5
  Version = "3.0.7"
  Id = "$Id$"

  def self.must_C_version
    self
  end

  def initialize str, fa = nil, fixed_anchor: false
    @str = str
    @regs = StringScanner::Regs.new
    @regex = nil
    @curr = 0
    @prev = 0
    @matched = false
    @fixed_anchor = !!fixed_anchor
  end

  def beginning_of_line?
    return if @curr > @str.bytesize
    return true if @curr == 0
    @str.getbyte(@curr - 1) == "\n".ord
  end
  alias :bol? :beginning_of_line?

  def captures
    return unless @matched

    (@regs.num_regs - 1).times.map { |i|
      extract_range(adjust_register_position(@regs.get_beg(i + 1)),
                    adjust_register_position(@regs.get_end(i + 1)))

    }
  end

  def charpos
    @str.byteslice(0, @curr).length
  end

  def check re
    strscan_do_scan_head(re) do |len|
      @str.byteslice(@prev, len)
    end
  end

  def check_until re
    strscan_do_scan(re) do |len|
      @str.byteslice(@prev, len)
    end
  end

  def concat str
    @str.concat str
  end
  alias :<< :concat

  def eos?
    @curr >= @str.bytesize
  end

  def exist? re
    strscan_do_scan(re) { |len| len }
  end

  def fixed_anchor?
    fixed_anchor
  end

  def get_byte
    @matched = false
    return if eos?
    @prev = @curr
    @curr += 1
    @matched = true
    adjust_registers_to_matched
    @str.byteslice(@prev, 1)
  end

  def getbyte
    warn "StringScanner#getbyte is obsolete; use #get_byte instead"
    get_byte
  end

  def getch
    @matched = false
    return if eos?
    str = @str[@curr]
    @prev = @curr
    @curr += str.bytesize
    @matched = true
    adjust_registers_to_matched
    str
  end

  def inspect
    if defined?(@str)
      if eos?
        "#<StringScanner fin>"
      else
        if @curr == 0
          "#<StringScanner #{@curr}/#{@str.bytesize} @ #{inspect2.dump}>"
        else
          "#<StringScanner #{@curr}/#{@str.bytesize} #{inspect1.dump} @ #{inspect2.dump}>"
        end
      end
    else
      "#<StringScanner (uninitialized)>"
    end
  end

  def match? re
    strscan_do_scan_head(re) { |len| len }
  end

  def matched
    return nil unless @matched
    extract_range(adjust_register_position(@regs.get_beg(0)),
                  adjust_register_position(@regs.get_end(0)))
  end

  def matched?
    @matched
  end

  def matched_size
    return nil unless @matched
    @regs.get_end(0) - @regs.get_beg(0)
  end

  def named_captures
    return {} unless @regex

    @regs.named_captures(@regex).transform_values! { |v| self[v] }
  end

  def peek len
    return "" if eos?

    @str.byteslice(@curr, len)
  end

  def pos= i
    i += @str.bytesize if i < 0
    raise(RangeError, "index out of range") if i < 0
    raise(RangeError, "index out of range") if i > @str.bytesize
    @curr = i
    i
  end

  def pos
    @curr
  end

  def post_match
    return unless @matched
    extract_range(adjust_register_position(@regs.get_end(0)), @str.bytesize)
  end

  def pre_match
    return unless @matched

    extract_range(0, adjust_register_position(@regs.get_beg(0)))
  end

  def reset
    @curr = 0
    @matched = false
    self
  end

  def rest
    return "" if eos?
    extract_range(@curr, @str.bytesize)
  end

  def rest_size
    return 0 if eos?
    s_restlen
  end

  def restsize
    warn "StringScanner#restsize is obsolete; use #rest_size instead"
    rest_size
  end

  def scan re
    strscan_do_scan_head(re) { |len|
      succ
      @str.byteslice(@prev, len)
    }
  end

  def scan_full re, advance_pointer, return_string
    strscan_do_scan_head(re) do |len|
      succ if advance_pointer

      if return_string
        @str.byteslice(@prev, len)
      else
        len
      end
    end
  end

  def scan_until re
    strscan_do_scan(re) do |len|
      succ
      @str.byteslice(@prev, len)
    end
  end

  def search_full re, advance_pointer, return_string
    strscan_do_scan(re) do |len|
      succ if advance_pointer

      if return_string
        @str.byteslice(@prev, len)
      else
        len
      end
    end
  end

  def size
    return unless @matched
    @regs.num_regs
  end

  def skip re
    strscan_do_scan_head(re) do |len|
      succ
      len
    end
  end

  def skip_until re
    strscan_do_scan(re) do |len|
      succ
      len
    end
  end

  def string
    @str
  end

  def string= str
    initialize(str, fixed_anchor: fixed_anchor)
    str
  end

  def terminate
    @curr = @str.bytesize
    @matched = false
  end

  def unscan
    unless @matched
      raise StringScanner::Error, "unscan failed: previous match record does not exist"
    end

    @curr = @prev
    @matched = false
  end

  def values_at *args
    return unless @matched

    args.map { |x| self[x] }
  end

  def [] i
    return unless @matched

    if i.is_a?(Symbol) || i.is_a?(String)
      return unless @regex
      i = @regs.name_to_backref_number(@regex, i.to_s)
    end

    i += @regs.num_regs if i < 0
    return if i < 0
    return if i >= @regs.num_regs
    return if @regs.get_beg(i) == -1

    extract_range(adjust_register_position(@regs.get_beg(i)),
                  adjust_register_position(@regs.get_end(i)))
  end

  private

  attr_reader :fixed_anchor

  def adjust_registers_to_matched
    @regs.clear
    if fixed_anchor
      @regs.region_set 0, @prev, @curr
    else
      @regs.region_set 0, 0, @curr - @prev
    end
  end

  def extract_range start, finish
    @str.byteslice(start, finish - start)
  end

  def adjust_register_position position
    if fixed_anchor
      position
    else
      @prev + position
    end
  end

  def inspect1
    return "" if @curr == 0

    if @curr > INSPECT_LENGTH
      str = "..."
      len = INSPECT_LENGTH
    else
      str = ""
      len = @curr
    end

    str + @str.byteslice(@curr - len, len)
  end

  def inspect2
    return "" if eos?

    len = s_restlen
    if len > INSPECT_LENGTH
      @str.byteslice(@curr, INSPECT_LENGTH) + "..."
    else
      @str.byteslice(@curr, len)
    end
  end

  def strscan_do_scan_head pattern
    @matched = false
    @regex = pattern

    return if @curr > @str.bytesize

    if pattern.is_a?(Regexp)
      @matched = @regs.onig_match(pattern, @str, @curr, fixed_anchor)
    else
      @matched = @regs.str_match(pattern, @str, @curr, fixed_anchor)
    end

    return unless @matched

    @prev = @curr

    yield last_match_length
  end

  def strscan_do_scan pattern
    @matched = false
    @regex = pattern

    return if @curr > @str.bytesize

    @matched = @regs.onig_search(pattern, @str, @curr, fixed_anchor)

    return unless @matched

    @prev = @curr

    yield last_match_length
  end

  def s_restlen
    @str.bytesize - @curr
  end

  def succ
    if fixed_anchor
      @curr = @matched
    else
      @curr += @matched
    end
  end

  def last_match_length
    if fixed_anchor
      @matched - @prev
    else
      @matched
    end
  end
end
