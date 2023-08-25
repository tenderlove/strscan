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
    strscan_do_scan(re, false, true, true)
  end

  def check_until re
    strscan_do_scan(re, false, true, false)
  end

  def concat str
    @str.concat str
  end
  alias :<< :concat

  def eos?
    @curr >= @str.bytesize
  end

  def exist? re
    strscan_do_scan(re, false, false, false)
  end

  def fixed_anchor?
    @fixed_anchor
  end

  def get_byte
    @matched = false
    return if eos?
    @prev = @curr
    @curr += 1
    @matched = true
    adjust_registers_to_matched
    extract_range(adjust_register_position(@regs.get_beg(0)),
                  adjust_register_position(@regs.get_end(0)))
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
    strscan_do_scan re, false, false, true
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
    strscan_do_scan(re, true, true, true)
  end

  def scan_full re, advance_pointer, return_string
    strscan_do_scan(re, advance_pointer, return_string, true)
  end

  def scan_until re
    strscan_do_scan(re, true, true, false)
  end

  def search_full re, advance_pointer, return_string
    strscan_do_scan(re, advance_pointer, return_string, false)
  end

  def size
    return unless @matched
    @regs.num_regs
  end

  def skip re
    strscan_do_scan(re, true, false, true)
  end

  def skip_until re
    strscan_do_scan(re, true, false, false)
  end

  def string
    @str
  end

  def string= str
    initialize(str, fixed_anchor: @fixed_anchor)
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

  def adjust_registers_to_matched
    @regs.clear
    if @fixed_anchor
      @regs.region_set 0, @prev, @curr
    else
      @regs.region_set 0, 0, @curr - @prev
    end
  end

  def extract_range start, finish
    @str.byteslice(start, finish - start)
  end

  def adjust_register_position position
    if @fixed_anchor
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

  def strscan_do_scan pattern, succptr, getstr, headonly
    if headonly
      if !pattern.is_a?(Regexp) && !pattern.is_a?(String)
        raise TypeError
      end
    else
      if !pattern.is_a?(Regexp)
        raise TypeError
      end
    end

    @matched = false
    @regex = pattern

    if s_restlen < 0
      return nil
    end

    if pattern.is_a?(Regexp)
      if headonly
        @matched = @regs.onig_match(pattern, @str, @curr, @fixed_anchor)
      else
        @matched = @regs.onig_search(pattern, @str, @curr, @fixed_anchor)
      end
    else
      @matched = @regs.str_match(pattern, @str, @curr, @fixed_anchor)
    end

    return unless @matched

    @prev = @curr
    succ if succptr

    len = last_match_length

    if getstr
      @str.byteslice(@prev, len)
    else
      len
    end
  end

  def s_restlen
    @str.bytesize - @curr
  end

  def succ
    if @fixed_anchor
      @curr = @regs.get_end(0)
    else
      @curr += @regs.get_end(0)
    end
  end

  def last_match_length
    if @fixed_anchor
      @regs.get_end(0) - @prev
    else
      @regs.get_end(0)
    end
  end
end
