#!/usr/bin/env ruby
# frozen_string_literal: true

# Re-records the two E/Z-butene identity rows from hand-laid
# coordinate molfiles (chemomer#128's follow-up: the SMILES reader now
# derives the /b layer, so the recorded identities must carry it —
# the rows were recorded from the gem writer's collinear layout, the
# stereo-ez-molfile-loss class, and the oracle correctly dropped the
# E/Z layer). The layouts are the record-ez-tranche.rb drawings: the
# substituents sit at drawn positions whose sides carry the E/Z.
#
#   ASCIICHEM_INCHI_BIN=inchi-1 ruby scripts/re-record-ez-butene.rb
#
# Surgical: only the two rows change; every other record stays
# byte-identical. Each field follows the recording conventions of the
# script that owns it (record-identity-oracle / record-aux-info /
# record-modes-oracle / record-donotaddh).

require 'json'
require 'tmpdir'

bin = ENV.fetch('ASCIICHEM_INCHI_BIN', 'inchi-1')
path = File.expand_path('../corpus/fixtures/identity.json', __dir__)

# The ez-tranche layouts: atoms [element, x, y]; bonds [a, b, order]
# (0-based). Trans draws the substituents on opposite sides; cis on
# the same side.
SEEDS = {
  'identity/e-2-butene' => ['stereo-ez', [%w[C 12 85], %w[C 60 50], %w[C 120 50], %w[C 168 15]],
                           [[0, 1, 1], [1, 2, 2], [2, 3, 1]]],
  'identity/z-2-butene' => ['stereo-ez', [%w[C 12 15], %w[C 60 50], %w[C 120 50], %w[C 168 15]],
                            [[0, 1, 1], [1, 2, 2], [2, 3, 1]]]
}.freeze

def molfile_for(name, atoms, bonds)
  molfile = +"#{name}\n  AsciiChem\n\n"
  molfile += format("%3d%3d  0  0  0  0  0  0  0  0999 V2000\n", atoms.length, bonds.length)
  atoms.each do |(element, x, y)|
    molfile += format("%10.4f%10.4f%10.4f %-3s 0  0  0  0  0  0  0  0  0  0  0  0  0\n",
                      x.to_f, y.to_f, 0.0, element)
  end
  bonds.each do |(a, b, order)|
    molfile += format("%3d%3d%3d%3d  0  0  0  0\n", a + 1, b + 1, order, 0)
  end
  molfile << "M  END\n"
  molfile
end

def run_oracle(bin, molfile, flags)
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 's.mol'), molfile)
    system(bin, File.join(dir, 's.mol'), File.join(dir, 'o.txt'), *flags,
           out: File::NULL, err: File::NULL)
    File.read(File.join(dir, 'o.txt'))
  end
end

rows = JSON.parse(File.read(path))
patched = 0
rows.each do |rec|
  seed = SEEDS[rec['id']]
  next unless seed

  klass, atoms, bonds = seed
  molfile = molfile_for(rec['id'], atoms, bonds)

  std = run_oracle(bin, molfile, ['-AuxNone', '-NoLabels', '-Key'])
  inchi = std[/^InChI=\S+/]
  key = std[/^InChIKey=(\S+)/, 1]
  raise "no standard InChI for #{rec['id']}" unless inchi && key

  aux_txt = run_oracle(bin, molfile, [])
  aux = aux_txt[/^AuxInfo=\S+/]
  raise "no aux for #{rec['id']}" unless aux

  rec['structureClass'] = klass
  rec['molfile'] = molfile
  rec['inchi'] = inchi
  rec['inchikey'] = key
  rec['aux'] = aux

  MODES = {
    'fixedh' => ['-FixedH'],
    'recmet' => ['-RecMet'],
    'snon' => ['-SNon']
  }.freeze
  MODES.each do |mode, flags|
    txt = run_oracle(bin, molfile, flags)
    lines = txt.scan(/^InChI=\S+/)
    mode_aux = txt[/^AuxInfo=\S+/]
    raise "no #{mode} output for #{rec['id']}" if lines.empty? || mode_aux.nil?

    rec[mode] = { 'inchi' => lines.length == 1 ? lines[0] : lines, 'aux' => mode_aux }
  end

  dna = run_oracle(bin, molfile, ['-Key', '-DoNotAddH'])
  dna_inchi = dna[/^InChI=\S+/]
  dna_aux = dna[/^AuxInfo=\S+/]
  raise "no DoNotAddH output for #{rec['id']}" unless dna_inchi && dna_aux

  rec['donotaddh'] = { 'inchi' => dna_inchi, 'aux' => dna_aux }
  patched += 1
end

raise "expected to patch 2 rows, patched #{patched}" unless patched == 2

File.write(path, JSON.pretty_generate(rows))
puts "patched #{patched} rows"
