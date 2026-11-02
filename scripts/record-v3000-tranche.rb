#!/usr/bin/env ruby
# frozen_string_literal: true

# Records corpus/fixtures/v3000-molfiles.json — the V3000 input
# tranche. A deterministic sample of existing fixtures' molfiles is
# converted to the V3000 flavor (the simplest faithful conversion:
# free-form V30 lines, the COUNTS line, CHG=/MASS=/CFG= attributes in
# the V30 form of the V2000 `M  CHG` / `M  ISO` property lines and the
# stereo column) and the IUPAC oracle records each identifier over the
# V3000 input, cross-checked against the source fixture's own V2000
# recording — a V3000 reading that disagrees with its V2000 twin
# aborts the recording. Development-time only: the corpus ships the
# recorded strings, never the oracle.
#
#   ASCIICHEM_INCHI_BIN=/path/to/inchi-1 \
#     ruby scripts/record-v3000-tranche.rb > corpus/fixtures/v3000-molfiles.json

require 'json'
require 'open3'
require 'set'
require 'tmpdir'

bin = ENV.fetch('ASCIICHEM_INCHI_BIN', 'inchi-1')
root = File.expand_path('..', __dir__)
fixtures_dir = File.join(root, 'corpus', 'fixtures')

# The deterministic sample across the corpus (~60 fixtures): an even
# spread over every source file, the small stereo/E/Z/metal and
# multi-component files taken more densely.
PLAN = {
  'identity.json' => 10,
  'identity-breadth.json' => 10,
  'identity-breadth2.json' => 10,
  'identity-breadth3.json' => 10,
  'identity-stereo.json' => 10,
  'identity-ez.json' => 5,
  'identity-metal.json' => 5,
  'identity-multicomponent.json' => 8
}.freeze

# n evenly-spaced rows (deterministic; no randomness to reproduce).
def sample(rows, n)
  return rows if rows.length <= n

  (0...n).map { |i| rows[(i * rows.length) / n] }
end

# The isotopic path must be in the tranche: any M ISO fixture of the
# sampled files joins the sample (the even spread above can miss
# them), so the V3000 MASS= attribute is exercised against the
# oracle's D/T and heavy-isotope handling.
def isotopic(rows)
  rows.select { |fixture| fixture['molfile'].include?('M  ISO') }
end

# The simplest faithful V2000 -> V3000 conversion: the counts line
# becomes the V3000 quasi-counts, each atom/bond line re-emits its
# fixed columns as free-form V30 fields, and the `M  CHG` / `M  ISO`
# property lines plus the bond stereo column become atom/bond
# attributes. Coordinates keep their exact source text — no float
# round-trip.
def to_v3000(molfile)
  lines = molfile.split("\n")
  counts = lines[3]
  n_atoms = counts[0, 3].to_i
  n_bonds = counts[3, 3].to_i
  atoms = lines[4, n_atoms]
  bonds = lines[4 + n_atoms, n_bonds] || []

  charges = {}
  isotopes = {}
  (lines[(4 + n_atoms + n_bonds)..] || []).each do |line|
    next unless line.start_with?('M  CHG', 'M  ISO')

    kind = line.start_with?('M  CHG') ? charges : isotopes
    values = line[6..].split
    values[1..].each_slice(2) { |(index, value)| kind[index.to_i] = value.to_i }
  end

  out = [lines[0], lines[1], '', '  0  0  0  0  0  0  0  0  0  0999 V3000',
         'M  V30 BEGIN CTAB', "M  V30 COUNTS #{n_atoms} #{n_bonds} 0 0 0",
         'M  V30 BEGIN ATOM']
  atoms.each_with_index do |line, k|
    attrs = +''
    attrs << " CHG=#{charges[k + 1]}" if charges.key?(k + 1)
    attrs << " MASS=#{isotopes[k + 1]}" if isotopes.key?(k + 1)
    out << "M  V30 #{k + 1} #{line[31, 3].strip} #{line[0, 10].strip} " \
           "#{line[10, 10].strip} 0 0#{attrs}"
  end
  out << 'M  V30 END ATOM'

  unless bonds.empty?
    out << 'M  V30 BEGIN BOND'
    bonds.each_with_index do |line, k|
      stereo = line[9, 3].to_s.strip.to_i
      cfg = { 1 => ' CFG=1', 4 => ' CFG=2', 6 => ' CFG=3' }.fetch(stereo, '')
      out << "M  V30 #{k + 1} #{line[6, 3].strip} #{line[0, 3].to_i} " \
             "#{line[3, 3].to_i}#{cfg}"
    end
    out << 'M  V30 END BOND'
  end

  out << 'M  V30 END CTAB' << 'M  END' << ''
  out.join("\n")
end

def oracle_record(bin, molfile)
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 's.mol'), molfile)
    _out, err, status = Open3.capture3(bin, File.join(dir, 's.mol'),
                                       File.join(dir, 'o.txt'),
                                       File.join(dir, 'o.log'),
                                       '-AuxNone', '-NoLabels', '-Key')
    txt = File.read(File.join(dir, 'o.txt'))
    inchi = txt[/^InChI=\S+/]
    key = txt[/^InChIKey=(\S+)/, 1]
    raise "oracle produced no InChI:\n#{txt}#{err}" unless inchi && key

    [inchi, key]
  end
end

rows = []
included = Set.new
PLAN.each do |file, n|
  source = JSON.parse(File.read(File.join(fixtures_dir, file)))
  sample(source, n).concat(isotopic(source)).each do |fixture|
    next if included.include?(fixture['id'])
    included.add(fixture['id'])

    v3000 = to_v3000(fixture['molfile'])
    inchi, key = oracle_record(bin, v3000)
    if inchi != fixture['inchi'] || key != fixture['inchikey']
      raise "V3000 reading disagrees with the V2000 recording for " \
            "#{fixture['id']}:\n  v2000: #{fixture['inchi']}\n  v3000: #{inchi}"
    end

    rows << {
      'id' => "v3000/#{fixture['id'].split('/').last}",
      'structureClass' => "#{fixture['structureClass']}+v3000",
      'source' => fixture['id'],
      'molfile' => v3000,
      'inchi' => inchi,
      'inchikey' => key
    }
  end
end

puts JSON.pretty_generate(rows)
