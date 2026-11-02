#!/usr/bin/env ruby
# frozen_string_literal: true

# Records corpus/fixtures/sdf-batch.json — the SDfile batch tranche.
# A deterministic sample of existing fixtures' molfiles becomes one
# 30-record SDF (each record carrying an <ID> data field), the IUPAC
# oracle reads the batch natively, and the recording keeps the SDF
# verbatim with the per-record identifiers in record order.
# Development-time only: the corpus ships the recorded strings, never
# the oracle.
#
#   ASCIICHEM_INCHI_BIN=/path/to/inchi-1 \
#     ruby scripts/record-sdf-tranche.rb > corpus/fixtures/sdf-batch.json

require 'json'
require 'open3'
require 'tmpdir'

bin = ENV.fetch('ASCIICHEM_INCHI_BIN', 'inchi-1')
root = File.expand_path('..', __dir__)
fixtures_dir = File.join(root, 'corpus', 'fixtures')

# The deterministic sample: 30 records spread over every identity
# file, the small stereo/E/Z/metal and multi-component files taken
# more densely.
PLAN = {
  'identity.json' => 4,
  'identity-breadth.json' => 5,
  'identity-breadth2.json' => 4,
  'identity-breadth3.json' => 4,
  'identity-stereo.json' => 4,
  'identity-ez.json' => 2,
  'identity-metal.json' => 2,
  'identity-multicomponent.json' => 5
}.freeze

# n evenly-spaced rows (deterministic; no randomness to reproduce).
def sample(rows, n)
  return rows if rows.length <= n

  (0...n).map { |i| rows[(i * rows.length) / n] }
end

sampled = PLAN.flat_map do |file, n|
  source = JSON.parse(File.read(File.join(fixtures_dir, file)))
  sample(source, n)
end

# The batch: each molfile verbatim plus one <ID> data field, records
# closed by the $$$$ terminator.
sdf = sampled.each_with_index.map do |fixture, index|
  "#{fixture['molfile']}> <ID>\nsdf/record-#{index}: #{fixture['id']}\n\n$$$$\n"
end.join

inches = nil
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'batch.sdf'), sdf)
  _out, err, _status = Open3.capture3(bin, File.join(dir, 'batch.sdf'),
                                      File.join(dir, 'o.txt'),
                                      File.join(dir, 'o.log'),
                                      '-AuxNone', '-NoLabels', '-Key')
  txt = File.read(File.join(dir, 'o.txt'))
  inches = txt.lines.map(&:strip).select { |line| line.start_with?('InChI=') }
  raise "the oracle produced #{inches.length} identifiers for " \
        "#{sampled.length} records:\n#{txt}#{err}" if inches.length != sampled.length
end

puts JSON.pretty_generate([{
  'id' => 'sdf-batch/30-record-sample',
  'structureClass' => 'sdf-batch',
  'sdf' => sdf,
  'inchis' => inches
}])
