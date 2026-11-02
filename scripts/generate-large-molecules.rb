#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates corpus/fixtures/large-molecules.json — the LargeMolecules
# tranche. Three linear polyethylene chains past the reference's
# normally-allowed input size (ichisize.h NORMALLY_ALLOWED_INP_MAX_ATOMS
# = 1024; the oracle's reader refuses them without -LargeMolecules)
# are built programmatically and the IUPAC oracle records each
# identifier under -LargeMolecules — the beta InChI=1B flavor the
# reference writes past that bound. The molfiles are necessarily
# V3000: the V2000 counts line caps at 999 atoms. The first chain
# sits one atom past the bound so the exact threshold stays pinned.
# Development-time only: the corpus ships the recorded strings, never
# the oracle.
#
#   ASCIICHEM_INCHI_BIN=/path/to/inchi-1 \
#     ruby scripts/generate-large-molecules.rb > corpus/fixtures/large-molecules.json

require 'json'
require 'open3'
require 'tmpdir'

bin = ENV.fetch('ASCIICHEM_INCHI_BIN', 'inchi-1')

# { id => carbon count } — chains of C(n)H(2n+2); the total atom
# count is the carbon count (hydrogens are implicit, never input
# atoms).
CHAINS = {
  'polyethylene-c1025' => 1025,
  'polyethylene-c1100' => 1100,
  'polyethylene-c1502' => 1502
}.freeze

# The zigzag layout: alternating y keeps the coordinates 2D-plausible;
# the chain carries no stereo, so the parity never enters the identity.
def alkane_v3000(carbons)
  out = ["polyethylene-C#{carbons}", '  generator', '',
         '  0  0  0  0  0  0  0  0  0  0999 V3000',
         'M  V30 BEGIN CTAB', "M  V30 COUNTS #{carbons} #{carbons - 1} 0 0 0",
         'M  V30 BEGIN ATOM']
  carbons.times do |k|
    out << "M  V30 #{k + 1} C #{k * 12} #{k.even? ? 12 : 20} 0 0"
  end
  out << 'M  V30 END ATOM' << 'M  V30 BEGIN BOND'
  (carbons - 1).times do |k|
    out << "M  V30 #{k + 1} 1 #{k + 1} #{k + 2}"
  end
  out << 'M  V30 END BOND' << 'M  V30 END CTAB' << 'M  END' << ''
  out.join("\n")
end

rows = CHAINS.map do |id, carbons|
  molfile = alkane_v3000(carbons)
  raise "#{id}: #{carbons} atoms miss the large-molecule bound" if carbons <= 1024

  inchi = nil
  key = nil
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 's.mol'), molfile)
    _out, err, _status = Open3.capture3(bin, File.join(dir, 's.mol'),
                                        File.join(dir, 'o.txt'),
                                        File.join(dir, 'o.log'),
                                        '-LargeMolecules', '-AuxNone', '-NoLabels', '-Key')
    txt = File.read(File.join(dir, 'o.txt'))
    inchi = txt[/^InChI=\S+/]
    key = txt[/^InChIKey=(\S+)/, 1]
    raise "oracle produced no InChI for #{id}:\n#{txt}#{err}" unless inchi && key
    raise "#{id}: the oracle did not speak the beta version: #{inchi}" unless inchi.start_with?('InChI=1B/')
  end

  {
    'id' => "large-molecules/#{id}",
    'structureClass' => 'large-molecule',
    'molfile' => molfile,
    'inchi' => inchi,
    'inchikey' => key
  }
end

puts JSON.pretty_generate(rows)
