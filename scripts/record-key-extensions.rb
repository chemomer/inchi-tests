#!/usr/bin/env ruby
# frozen_string_literal: true

# Records the oracle's InChIKey hash extensions for a corpus tranche
# spanning the small structure families (simple, ring, charge, isotope,
# stereo-tetrahedral, stereo-ez, drug-sized): each selected fixture
# gains
#   "inchikey_xhash1" => the 256-bit extension of the FIRST key block
#                        (48 lowercase hex chars, digest bits 65..255)
#   "inchikey_xhash2" => the 256-bit extension of the SECOND block
#                        (56 lowercase hex chars, digest bits 37..255)
#   "inchikey_merged" => the oracle's merged InChIHash= line
#                        (-Key -XHash1 -XHash2 -MergeHash)
# Each shape is one batch SDF run of the CLEAN inchi-1 executable
# (ASCIICHEM_INCHI_BIN points at it):
#   A: -Key -XHash1 -XHash2            (InChIKey=, XHash1=, XHash2= lines)
#   B: -Key -XHash1 -XHash2 -MergeHash (the merged InChIHash= line)
# Development-time tooling — the corpus ships the recorded strings.
#
#   ASCIICHEM_INCHI_BIN=/path/to/inchi-1 ruby scripts/record-key-extensions.rb
# Per-record invariant: the recorded standard key ("inchikey") must
# still match the freshly recorded InChIKey line.

require 'json'
require 'tmpdir'

FAMILY_CLASSES = %w[
  simple heteroatom ring ring-fused heteroaromatic
  charge charge-2 isotope
  stereo-tetrahedral stereo-ez
  drug drug-stereo amino-acid
].freeze
TRANCHE_CAP = 40

bin = ENV.fetch('ASCIICHEM_INCHI_BIN')
fixtures_dir = File.expand_path('../corpus/fixtures', __dir__)
files = Dir[File.join(fixtures_dir, '*.json')].sort

all_records = {}
files.each { |path| all_records[path] = JSON.parse(File.read(path)) }

selected = []
all_records.each_value do |recs|
  recs.each do |rec|
    next unless FAMILY_CLASSES.include?(rec['structureClass'])

    selected << rec
  end
end
selected = selected.first(TRANCHE_CAP)
puts "tranche records: #{selected.length}"

def parse_blocks(txt)
  out = {}
  blocks = txt.split(/^Structure: (\d+)\n/)
  blocks.drop(1).each_slice(2) do |n, body|
    break if n.nil? || body.nil?

    out[n.to_i] = body
  end
  out
end

Dir.mktmpdir do |dir|
  sdf = File.join(dir, 'batch.sdf')
  File.open(sdf, 'w') do |f|
    selected.each { |rec| f.write(rec['molfile'].to_s + "$$$$\n") }
  end

  run = lambda do |name, *flags|
    out = File.join(dir, "o-#{name}.txt")
    system(bin, sdf, out, File.join(dir, "o-#{name}.log"), *flags,
           out: File::NULL, err: File::NULL)
    parse_blocks(File.read(out))
  end

  plain = run.call('plain', '-Key', '-XHash1', '-XHash2')
  merged = run.call('merged', '-Key', '-XHash1', '-XHash2', '-MergeHash')

  missing = 0
  mismatches = 0
  selected.each_with_index do |rec, i|
    plain_block = plain[i + 1]
    merged_block = merged[i + 1]
    key = plain_block&.[](/^InChIKey=(\S+)/, 1)
    xhash1 = plain_block&.[](/^XHash1=(\S+)/, 1)
    xhash2 = plain_block&.[](/^XHash2=(\S+)/, 1)
    merged_line = merged_block&.[](/^InChIHash=(\S+)/, 1)
    if key.nil? || xhash1.nil? || xhash2.nil? || merged_line.nil?
      missing += 1
      warn "MISSING key-extension output for #{rec['id']}"
      next
    end
    unless key == rec['inchikey']
      mismatches += 1
      warn "STANDARD KEY MISMATCH #{rec['id']}: #{key} != #{rec['inchikey']}"
      next
    end
    expected_merged = "#{key}-#{xhash1}-#{xhash2}"
    if merged_line != expected_merged
      mismatches += 1
      warn "MERGED MISMATCH #{rec['id']}: #{merged_line} != #{expected_merged}"
      next
    end
    rec['inchikey_xhash1'] = xhash1
    rec['inchikey_xhash2'] = xhash2
    rec['inchikey_merged'] = "InChIHash=#{merged_line}"
  end
  warn "missing #{missing}, mismatches #{mismatches}"
  exit 1 if missing.positive? || mismatches.positive?
end

all_records.each { |path, recs| File.write(path, JSON.pretty_generate(recs) + "\n") }
puts 'done'
