#!/usr/bin/env ruby
# frozen_string_literal: true

# Records the RInChI reaction tranche from the IUPAC RInChI oracle
# (rinchi_cmdline). Same contract as record-identity-oracle.rb: the
# oracle (and the InChI 1 engine behind it) is a development-time
# test oracle — the corpus ships only the recorded strings.
#
# Every reaction composes whole molecules as RXNfile $MOL blocks:
# one block per role entry, reactants first, then products, then
# agents. Component molfiles come from the existing identity fixtures
# where one exists (provenance stays inside the corpus); the few
# small species the corpus lacks (water's reaction partners: O2, CO2,
# HCl, ...) are written inline below and were verified against the
# InChI oracle before recording.
#
#   cd /tmp/rinchi/src/example_apps/rinchi_cmdline && make -f Makefile-Mac
#   RINCHI_BIN=/tmp/rinchi/src/example_apps/rinchi_cmdline/rinchi_cmdline \
#     ASCIICHEM_INCHI_BIN=/tmp/inchi-clean-build/INCHI-1-SRC/INCHI_EXE/inchi-1/src/bin/inchi-1 \
#     bundle exec ruby scripts/record-rinchi-tranche.rb \
#     > corpus/fixtures/rinchi-reactions.json

require 'json'
require 'tmpdir'

FIXTURES_DIR = File.join(__dir__, '..', 'corpus', 'fixtures')

# Loads the molfile of an existing identity fixture by id.
def fixture_molfile(id)
  Dir.glob(File.join(FIXTURES_DIR, 'identity*.json')).each do |path|
    row = JSON.parse(File.read(path)).find { |entry| entry['id'] == id }
    return row['molfile'] if row
  end
  raise "no fixture #{id}"
end

# Inline V2000 molfile for a species the corpus lacks.
def inline_molfile(name, atoms, bonds, charges = nil)
  out = +"#{name}\n  chemomer\n\n"
  out << format("%3d%3d  0  0  0  0  0  0  0  0999 V2000\n", atoms.length, bonds.length)
  atoms.each_with_index do |element, i|
    out << format('%10.4f%10.4f%10.4f %-3s', 12.0 + 12 * i, 12.0, 0.0, element)
    out << " 0  0  0  0  0  0  0  0  0  0  0  0\n"
  end
  bonds.each do |(a, b, kind)|
    out << format("%3d%3d%3d  0\n", a + 1, b + 1, kind)
  end
  if charges
    out << 'M  CHG' + format('%3d', charges.length)
    charges.each { |(atom, charge)| out << format('%4d%4d', atom + 1, charge) }
    out << "\n"
  end
  out << "M  END\n"
  out
end

HAND_WRITTEN = {
  'acetic-acid'   => inline_molfile('acetic acid',   %w[C C O O], [[0, 1, 1], [1, 2, 2], [1, 3, 1]]),
  'ethyl-acetate' => inline_molfile('ethyl acetate', %w[C C O C C O], [[0, 1, 1], [1, 2, 1], [2, 3, 1], [3, 4, 1], [3, 5, 2]]),
  'co2'           => inline_molfile('carbon dioxide', %w[C O O], [[0, 1, 2], [0, 2, 2]]),
  'o2'            => inline_molfile('oxygen', %w[O O], [[0, 1, 2]]),
  'acetylene'     => inline_molfile('acetylene', %w[C C], [[0, 1, 3]]),
  'ethene'        => inline_molfile('ethene', %w[C C], [[0, 1, 2]]),
  'chlorobenzene' => inline_molfile('chlorobenzene', %w[C C C C C C Cl],
                                    [[0, 1, 2], [1, 2, 1], [2, 3, 2], [3, 4, 1], [4, 5, 2], [5, 0, 1], [1, 6, 1]]),
  'cl2'           => inline_molfile('chlorine', %w[Cl Cl], [[0, 1, 1]]),
  'hcl'           => inline_molfile('hydrogen chloride', %w[H Cl], [[0, 1, 1]]),
  'chloromethane' => inline_molfile('chloromethane', %w[C Cl], [[0, 1, 1]]),
  'salicylic-acid' => inline_molfile('salicylic acid',
                                     %w[C C C C C C C O O O],
                                     [[0, 1, 2], [1, 2, 1], [2, 3, 2], [3, 4, 1], [4, 5, 2], [5, 0, 1],
                                      [0, 6, 1], [6, 7, 2], [6, 8, 1], [1, 9, 1]]),
  'nitric-acid'   => inline_molfile('nitric acid', %w[H O N O O],
                                    [[0, 1, 1], [1, 2, 1], [2, 3, 2], [2, 4, 1]],
                                    [[2, 1], [4, -1]]),
  'nitrobenzene'  => inline_molfile('nitrobenzene', %w[C C C C C C N O O],
                                    [[0, 1, 2], [1, 2, 1], [2, 3, 2], [3, 4, 1], [4, 5, 2], [5, 0, 1],
                                     [5, 6, 1], [6, 7, 2], [6, 8, 1]],
                                    [[6, 1], [8, -1]]),
  'placeholder'   => inline_molfile('unknown structure', %w[A], [])
}.freeze

CORPUS = {
  'water'          => 'identity/water',
  'methane'        => 'identity/methane',
  'ammonia'        => 'identity/ammonia',
  'ethanol'        => 'identity/ethanol',
  'benzene'        => 'identity/benzene',
  'urea'           => 'identity/urea',
  'sulfuric-acid'  => 'identity/sulfuric-acid',
  'aspirin'        => 'identity/aspirin',
  'e-2-butene'     => 'identity/e-2-butene',
  'z-2-butene'     => 'identity/z-2-butene',
  'l-alanine'      => 'identity/l-alanine',
  'd-alanine'      => 'identity/d-alanine'
}.freeze

def molfile_for(species)
  CORPUS.key?(species) ? fixture_molfile(CORPUS[species]) : HAND_WRITTEN.fetch(species)
end

# { id => [reactants, products, agents] } — species keys into the
# molfile tables above; a species may repeat (stoichiometry).
REACTIONS = {
  'rinchi/water-is-water'          => [%w[water], %w[water], []],
  'rinchi/esterification'          => [%w[acetic-acid ethanol], %w[ethyl-acetate water], []],
  'rinchi/ester-hydrolysis'        => [%w[ethyl-acetate water], %w[acetic-acid ethanol], []],
  'rinchi/catalyzed-esterification' => [%w[acetic-acid ethanol], %w[ethyl-acetate water], %w[sulfuric-acid]],
  'rinchi/aspirin-hydrolysis'      => [%w[aspirin water], %w[salicylic-acid acetic-acid], []],
  'rinchi/combustion-of-methane'   => [%w[methane o2 o2], %w[co2 water water], []],
  'rinchi/acetylene-trimerization' => [%w[acetylene acetylene acetylene], %w[benzene], []],
  'rinchi/ethene-hydration'        => [%w[ethene water], %w[ethanol], %w[sulfuric-acid]],
  'rinchi/benzene-chlorination'    => [%w[benzene cl2], %w[chlorobenzene hcl], []],
  'rinchi/methane-chlorination'    => [%w[methane cl2], %w[chloromethane hcl], []],
  'rinchi/butene-isomerization'    => [%w[e-2-butene], %w[z-2-butene], []],
  'rinchi/alanine-racemization'    => [%w[l-alanine], %w[d-alanine], []],
  'rinchi/woehler-urea-synthesis'  => [%w[co2 ammonia ammonia], %w[urea water], []],
  'rinchi/benzene-nitration'       => [%w[benzene nitric-acid], %w[nitrobenzene water], []],
  'rinchi/gas-phase-unknown-product' => [%w[ammonia hcl], [], []],
  'rinchi/water-to-unknown'        => [%w[water], %w[placeholder], []]
}.freeze

def write_rxn(id, reactants, products, agents)
  name = id.split('/').last
  out = +"$RXN\n#{name}\n  chemomer recording\n\n"
  out << format('%3d%3d', reactants.length, products.length)
  out << format('%3d', agents.length) unless agents.empty?
  out << "\n"
  (reactants + products + agents).each do |species|
    out << "$MOL\n"
    out << molfile_for(species)
  end
  out
end

rinchi_bin = ENV.fetch('RINCHI_BIN', 'rinchi_cmdline')
inchi_bin = ENV.fetch('ASCIICHEM_INCHI_BIN', 'inchi-1')

rows = []
REACTIONS.each do |id, (reactants, products, agents)|
  rxnfile = write_rxn(id, reactants, products, agents)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'r.rxn')
    File.write(path, rxnfile)
    output = `#{rinchi_bin} #{path} 2>&1`
    lines = output.split("\n")
    rinchi = lines.find { |l| l.start_with?('RInChI=') }
    rauxinfo = lines.find { |l| l.start_with?('RAuxInfo=') }
    long_key = lines.find { |l| l.start_with?('Long-RInChIKey=') }
    short_key = lines.find { |l| l.start_with?('Short-RInChIKey=') }
    web_key = lines.find { |l| l.start_with?('Web-RInChIKey=') }
    raise "oracle produced no RInChI for #{id}:\n#{output}" unless rinchi && rauxinfo && short_key

    # Per-component standard InChIs (debugging aid): every component
    # block re-runs through the InChI oracle, RXN role order kept.
    components = (reactants + products + agents).map do |species|
      mol = molfile_for(species)
      File.write(File.join(dir, 'c.mol'), mol)
      system(inchi_bin, File.join(dir, 'c.mol'), File.join(dir, 'c.txt'),
             '-AuxInfo', '-Key', out: File::NULL, err: File::NULL)
      txt = File.read(File.join(dir, 'c.txt'))
      {
        'species' => species,
        'inchi' => txt[/^InChI=\S+/] || 'InChI=1S/',
        'aux' => txt[/^AuxInfo=\S+/] || 'AuxInfo=1/',
        'inchikey' => txt[/^InChIKey=(\S+)/, 1] || 'MOSFIJXAXDLOML-UHFFFAOYSA-N'
      }
    end

    rows << { 'id' => id,
              'rxnfile' => rxnfile,
              'rinchi' => rinchi,
              'rauxinfo' => rauxinfo,
              'rinchikey' => short_key[/^Short-RInChIKey=(\S+)/, 1],
              'longKey' => long_key ? long_key[/=(\S+)$/, 1] : nil,
              'webKey' => web_key ? web_key[/=(\S+)$/, 1] : nil,
              'components' => components }
  end
end
puts JSON.pretty_generate(rows)
