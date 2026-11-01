#!/usr/bin/env ruby
# frozen_string_literal: true

# Records the oracle's -DoNotAddH output for every fixture record.
# One batch SDF run of the CLEAN inchi-1 executable (use
# ASCIICHEM_INCHI_BIN to point at it); each fixture gains
# "donotaddh" => { "inchi" => String, "aux" => String }.
# Development-time tooling — the corpus ships the recorded strings.
#
#   ruby scripts/record-donotaddh.rb
#
# DoNotAddH rewrites the identifier wholesale (only drawn hydrogens
# exist, so the formula, /h and the proton balance all change), so the
# standard line cannot be prefix-compared the way the FixedH/RecMet/
# SNon recording does. The invariants checked per record instead:
#   - the line is STANDARD-LEGAL (InChI=1S/ — DoNotAddH never turns
#     the std flag off, ichiparm.c);
#   - the heavy-element multiset of the formula equals the standard
#     recording's (the drawn composition never changes);
#   - AuxInfo present (a full read, not a skipped structure).

require 'json'
require 'tmpdir'

bin = ENV.fetch('ASCIICHEM_INCHI_BIN')
fixtures_dir = File.expand_path('../corpus/fixtures', __dir__)
files = Dir[File.join(fixtures_dir, '*.json')].sort

records = []
files.each do |path|
  JSON.parse(File.read(path)).each { |rec| records << [path, rec] }
end
puts "records: #{records.length}"

def parse_blocks(txt)
  out = {}
  blocks = txt.split(/^Structure: (\d+)\n/)
  blocks.drop(1).each_slice(2) do |n, body|
    break if n.nil? || body.nil?

    inchi = body[/^InChI=\S+/]
    aux = body[/^AuxInfo=\S+/]
    out[n.to_i] = { 'inchi' => inchi, 'aux' => aux }
  end
  out
end

# The formula's element counts, hydrogens included — dot-separated
# components each with an optional leading multiplier, e.g.
# "K.Mn.2H2O.2O" -> {"K"=>1,"Mn"=>1,"H"=>4,"O"=>4}.
def element_counts(formula)
  counts = Hash.new(0)
  formula.split('.').each do |component|
    component =~ /\A(\d*)(.*)\z/
    multiplier = Regexp.last_match(1).to_i
    multiplier = 1 if multiplier.zero?
    Regexp.last_match(2).scan(/([A-Z][a-z]?)(\d*)/) do |element, repeat|
      counts[element] += multiplier * (repeat.empty? ? 1 : repeat.to_i)
    end
  end
  counts
end

Dir.mktmpdir do |dir|
  sdf = File.join(dir, 'batch.sdf')
  File.open(sdf, 'w') do |f|
    records.each { |(_, rec)| f.write(rec['molfile'].to_s + "$$$$\n") }
  end

  out = File.join(dir, 'o-donotaddh.txt')
  system(bin, sdf, out, File.join(dir, 'o-donotaddh.log'),
         '-Key', '-DoNotAddH', out: File::NULL, err: File::NULL)
  parsed = parse_blocks(File.read(out))

  missing = 0
  mismatches = 0
  records.each_with_index do |(_path, rec), i|
    block = parsed[i + 1]
    if block.nil? || block['aux'].nil? || block['inchi'].nil? || block['inchi'].empty?
      missing += 1
      warn "MISSING donotaddh output for #{rec['id']}"
      next
    end
    line = block['inchi']
    # DoNotAddH is standard-legal: the version letter stays.
    unless line.start_with?('InChI=1S/')
      mismatches += 1
      warn "NOT STANDARD (donotaddh) #{rec['id']}: #{line}"
      next
    end
    # The heavy composition never changes: the DoNotAddH formula's
    # element multiset minus hydrogens must equal the standard's.
    heavy = ->(text) do
      counts = element_counts(text[/InChI=1S?\/([^\/]+)/, 1] || '')
      counts.delete('H')
      counts
    end
    if heavy.call(line) != heavy.call(rec['inchi'])
      mismatches += 1
      warn "FORMULA MISMATCH (donotaddh) #{rec['id']}: #{line} vs #{rec['inchi']}"
      next
    end
    rec['donotaddh'] = { 'inchi' => line, 'aux' => block['aux'] }
  end
  warn "donotaddh: missing #{missing}, invariant mismatches #{mismatches}"
  exit 1 if missing.positive? || mismatches.positive?
end

records.group_by(&:first).each do |path, pairs|
  File.write(path, JSON.pretty_generate(pairs.map(&:last)) + "\n")
end
puts 'done'
