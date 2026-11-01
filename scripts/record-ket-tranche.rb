#!/usr/bin/env ruby
# frozen_string_literal: true

# Records corpus/fixtures/tautomer-extremes.json — the experimental
# tautomerism tranche: hand-built tautomer-rich structures
# (beta-diketones, keto-enols, 1,5-dicarbonyl/imine chains,
# nitroso-oximes, cyanic acids, imines/enamines, nitrones,
# sulfoxides/sulfones) recorded under EVERY experimental flag
# combination: the standard run, -KET, -15T, -KET -15T, and each
# -PT_*. Each fixture gains "<mode>" => { "inchi" => String }.
# Development-time tooling — the corpus ships the recorded strings.
#
#   ASCIICHEM_INCHI_BIN=inchi-1 ruby scripts/record-ket-tranche.rb \
#     > corpus/fixtures/tautomer-extremes.json

require 'json'
require 'tmpdir'

# { id => [class, atoms, bonds] } — atoms [element, charge-or-nil];
# bonds [a, b, order] (0-based). Hydrogen counts are the reader's
# valence-gap inference (no drawn H); charges land in M  CHG.
SEEDS = {
  # --- beta-diketones and keto-enols (the KET slice) ---
  'pentane-2-4-dione' => ['taut-beta-diketone',
                          [['C', nil], ['C', nil], ['O', nil], ['C', nil], ['C', nil], ['O', nil], ['C', nil]],
                          [[0, 1, 1], [1, 2, 2], [1, 3, 1], [3, 4, 1], [4, 5, 2], [4, 6, 1]]],
  'cyclohexane-1-3-dione' => ['taut-beta-diketone-ring',
                              [['C'], ['C'], ['C'], ['C'], ['C'], ['C'], ['O'], ['O']].map { |(e)| [e, nil] },
                              [[0, 1, 2], [1, 2, 1], [2, 3, 1], [3, 4, 1], [4, 5, 1], [5, 0, 1], [1, 6, 2], [3, 7, 2]]],
  'propan-2-one' => ['taut-keto-enol',
                     [['C'], ['C'], ['O'], ['C']].map { |(e)| [e, nil] },
                     [[0, 1, 1], [1, 2, 2], [1, 3, 1]]],
  'prop-1-en-2-ol' => ['taut-keto-enol',
                       [['C'], ['C'], ['O'], ['C']].map { |(e)| [e, nil] },
                       [[0, 1, 1], [1, 2, 1], [1, 3, 2]]],
  'cyclohexanone' => ['taut-keto-enol-ring',
                      [['C'], ['C'], ['C'], ['C'], ['C'], ['C'], ['O']].map { |(e)| [e, nil] },
                      [[0, 1, 1], [1, 2, 1], [2, 3, 1], [3, 4, 1], [4, 5, 1], [5, 0, 1], [0, 6, 2]]],
  'cyclohex-1-en-1-ol' => ['taut-keto-enol-ring',
                           [['C'], ['C'], ['C'], ['C'], ['C'], ['C'], ['O']].map { |(e)| [e, nil] },
                           [[0, 1, 1], [1, 2, 2], [2, 3, 1], [3, 4, 1], [4, 5, 1], [5, 0, 1], [1, 6, 1]]],
  # --- 1,5-dicarbonyl / imine chains (the 15T slice) ---
  'glutaconaldehyde-imine' => ['taut-1-5-chain',
                               [['O'], ['C'], ['C'], ['C'], ['N']].map { |(e)| [e, nil] },
                               [[0, 1, 2], [1, 2, 1], [2, 3, 2], [3, 4, 1]]],
  'glutaconaldehyde-imine-enol' => ['taut-1-5-chain',
                                    [['O'], ['C'], ['C'], ['C'], ['N']].map { |(e)| [e, nil] },
                                    [[0, 1, 1], [1, 2, 2], [2, 3, 1], [3, 4, 2]]],
  'but-2-enedial' => ['taut-1-5-chain',
                      [['O'], ['C'], ['C'], ['C'], ['C'], ['O']].map { |(e)| [e, nil] },
                      [[0, 1, 2], [1, 2, 1], [2, 3, 2], [3, 4, 1], [4, 5, 2]]],
  'but-2-enedial-bisenol' => ['taut-1-5-chain',
                              [['O'], ['C'], ['C'], ['C'], ['C'], ['O']].map { |(e)| [e, nil] },
                              [[0, 1, 1], [1, 2, 2], [2, 3, 1], [3, 4, 2], [4, 5, 1]]],
  # --- nitroso-oximes (PT_16_00 / PT_06_00) ---
  'formaldoxime' => ['taut-nitroso-oxime',
                     [['C'], ['N'], ['O']].map { |(e)| [e, nil] },
                     [[0, 1, 2], [1, 2, 1]]],
  'nitrosomethane' => ['taut-nitroso-oxime',
                       [['C'], ['N'], ['O']].map { |(e)| [e, nil] },
                       [[0, 1, 1], [1, 2, 2]]],
  'acetaldoxime' => ['taut-nitroso-oxime',
                     [['C'], ['C'], ['N'], ['O']].map { |(e)| [e, nil] },
                     [[0, 1, 1], [1, 2, 2], [2, 3, 1]]],
  # --- cyanic acids (PT_18_00) ---
  'cyanic-acid' => ['taut-cyanic',
                    [['O'], ['C'], ['N']].map { |(e)| [e, nil] },
                    [[0, 1, 1], [1, 2, 3]]],
  'isocyanic-acid' => ['taut-cyanic',
                       [['N'], ['C'], ['O']].map { |(e)| [e, nil] },
                       [[0, 1, 2], [1, 2, 2]]],
  # --- imines / enamines (PT_22_00 / PT_06_00) ---
  'N-methyl-ethanimine' => ['taut-imine',
                            [['C'], ['C'], ['N'], ['C']].map { |(e)| [e, nil] },
                            [[0, 1, 1], [1, 2, 2], [2, 3, 1]]],
  'ethylidenimine-enamine-tautomer' => ['taut-imine',
                                        [['C'], ['C'], ['N'], ['C']].map { |(e)| [e, nil] },
                                        [[0, 1, 1], [1, 2, 1], [2, 3, 2]]],
  'diazene-methane' => ['taut-hetero-ene',
                        [['C'], ['N'], ['N']].map { |(e)| [e, nil] },
                        [[0, 1, 2], [1, 2, 1]]],
  'azo-methane-tautomer' => ['taut-hetero-ene',
                             [['C'], ['N'], ['N']].map { |(e)| [e, nil] },
                             [[0, 1, 1], [1, 2, 2]]],
  # --- nitrones (PT_39_00) ---
  'C-methyl-N-methyl-nitrone' => ['taut-nitrone',
                                  [['C', nil], ['C', nil], ['N', 1], ['O', -1], ['C', nil]],
                                  [[0, 1, 1], [1, 2, 2], [2, 3, 1], [2, 4, 1]]],
  'nitrone-N-oxide-tautomer' => ['taut-nitrone',
                                 [['C'], ['C'], ['N'], ['O'], ['C']].map { |(e)| [e, nil] },
                                 [[0, 1, 1], [1, 2, 1], [2, 3, 2], [2, 4, 1]]],
  # --- ketene/ethynol (PT_13_00) ---
  'ketene' => ['taut-ketene',
               [['O'], ['C'], ['C']].map { |(e)| [e, nil] },
               [[0, 1, 2], [1, 2, 2]]],
  'ethynol' => ['taut-ketene',
                [['O'], ['C'], ['C']].map { |(e)| [e, nil] },
                [[0, 1, 1], [1, 2, 3]]],
  # --- sulfur centers (the fix_special_bonds protections) ---
  'dimethyl-sulfoxide' => ['taut-sulfoxide',
                           [['C'], ['S'], ['O'], ['C']].map { |(e)| [e, nil] },
                           [[0, 1, 1], [1, 2, 2], [1, 3, 1]]],
  'dimethyl-sulfone' => ['taut-sulfone',
                         [['C'], ['S'], ['O'], ['O'], ['C']].map { |(e)| [e, nil] },
                         [[0, 1, 1], [1, 2, 2], [1, 3, 2], [1, 4, 1]]]
}.freeze

MODES = {
  'ket' => ['-KET'],
  't15' => ['-15T'],
  'ket15t' => ['-KET', '-15T'],
  'pt22' => ['-PT_22_00'],
  'pt16' => ['-PT_16_00'],
  'pt06' => ['-PT_06_00'],
  'pt39' => ['-PT_39_00'],
  'pt13' => ['-PT_13_00'],
  'pt18' => ['-PT_18_00']
}.freeze

bin = ENV.fetch('ASCIICHEM_INCHI_BIN', 'inchi-1')

def molfile_of(name, atoms, bonds)
  charged = atoms.each_with_index.select { |(element, charge), _| charge }
  molfile = +"#{name}\n  AsciiChem\n\n"
  molfile += format("%3d%3d  0  0  0  0  0  0  0  0999 V2000\n", atoms.length, bonds.length)
  atoms.each do |(element, _)|
    molfile += format("%10.4f%10.4f%10.4f %-3s 0  0  0  0  0  0  0  0  0  0  0  0  0\n",
                      0.0, 0.0, 0.0, element)
  end
  bonds.each do |(a, b, order)|
    molfile += format("%3d%3d%3d%3d  0  0  0  0\n", a + 1, b + 1, order, 0)
  end
  unless charged.empty?
    molfile += format("M  CHG%3d", charged.length)
    charged.each { |((_, charge), index)| molfile += format("%4d%4d", index + 1, charge) }
    molfile << "\n"
  end
  molfile << "M  END\n"
  molfile
end

rows = []
SEEDS.each do |name, (klass, atoms, bonds)|
  plain_atoms = atoms.map { |pair| pair.is_a?(Array) && pair.length == 2 ? pair : [pair[0], nil] }
  molfile = molfile_of(name, plain_atoms, bonds)
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 's.mol'), molfile)
    system(bin, File.join(dir, 's.mol'), File.join(dir, 'o.txt'),
           '-AuxNone', '-NoLabels', '-Key', out: File::NULL, err: File::NULL)
    txt = File.read(File.join(dir, 'o.txt'))
    inchi = txt[/InChI=\S+/]
    key = txt[/InChIKey=(\S+)/, 1]
    raise "oracle produced no InChI for #{name}:\n#{txt}" unless inchi && key

    record = { 'id' => "identity/#{name}", 'structureClass' => klass,
               'tags' => [], 'molfile' => molfile,
               'inchi' => inchi, 'inchikey' => key }
    MODES.each do |mode, flags|
      system(bin, File.join(dir, 's.mol'), File.join(dir, "o-#{mode}.txt"),
             File.join(dir, "o-#{mode}.log"), *flags, '-NoLabels',
             out: File::NULL, err: File::NULL)
      mode_txt = File.read(File.join(dir, "o-#{mode}.txt"))
      mode_inchi = mode_txt[/InChI=\S+/]
      raise "oracle produced no #{mode} InChI for #{name}:\n#{mode_txt}" unless mode_inchi

      record[mode] = { 'inchi' => mode_inchi }
    end
    rows << record
  end
end

puts JSON.pretty_generate(rows)
