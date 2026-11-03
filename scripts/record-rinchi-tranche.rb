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
  'placeholder'   => inline_molfile('unknown structure', %w[A], []),
  # The metal-O tranche's inline species: connected metal-oxygen
  # frameworks the identity tranches cover as fixture molfiles, the
  # small salts and oxides written here (charges ride the M  CHG
  # property line the reference reads).
  'nahco3'        => inline_molfile('sodium bicarbonate', %w[C O O O Na],
                                    [[0, 1, 2], [0, 2, 1], [0, 3, 1], [3, 4, 1]],
                                    [[3, -1]]),
  'nacl-ions'     => inline_molfile('sodium chloride', %w[Na Cl], [], [[0, 1], [1, -1]]),
  'agcl'          => inline_molfile('silver chloride', %w[Ag Cl], [], [[1, -1]]),
  'cuox'          => inline_molfile('copper oxalate', %w[Cu C O O C O O],
                                    [[0, 1, 1], [1, 2, 2], [1, 3, 1], [3, 4, 1], [4, 5, 2], [4, 6, 1], [6, 0, 1]],
                                    [[2, -1], [5, -1]]),
  'cuo'           => inline_molfile('copper oxide', %w[Cu O], [[0, 1, 1]], [[1, -2]]),
  'niso4'         => inline_molfile('nickel sulfate', %w[Ni O S O O O],
                                    [[0, 1, 1], [1, 2, 1], [2, 3, 2], [2, 4, 2], [2, 5, 1]],
                                    [[1, -1], [5, -1]]),
  'zno'           => inline_molfile('zinc oxide', %w[Zn O], [[0, 1, 1]], [[1, -2]]),
  'zncl2'         => inline_molfile('zinc chloride', %w[Zn Cl Cl], [], [[0, 2], [1, -1], [2, -1]]),
  'feco3'         => inline_molfile('iron carbonate', %w[Fe O C O O],
                                    [[0, 1, 1], [1, 2, 1], [2, 3, 2], [2, 4, 1]],
                                    [[3, -1], [4, -1]]),
  'feo'           => inline_molfile('iron oxide', %w[Fe O], [[0, 1, 2]], [[1, -2]])
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
  'd-alanine'      => 'identity/d-alanine',
  # The connected metal-O components come from the identity metal
  # tranches' fixture molfiles (provenance stays inside the corpus).
  'metal-sodium-phenoxide-bonded'  => 'identity/metal-sodium-phenoxide-bonded',
  'metal-sodium-acetate-bonded'    => 'identity/metal-sodium-acetate-bonded',
  'metal-silver-nitrate-bonded'    => 'identity/metal-silver-nitrate-bonded',
  'metal-ethyl-magnesium-bromide'  => 'identity/metal-ethyl-magnesium-bromide',
  'metal-methyl-copper'            => 'identity/metal-methyl-copper'
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
  'rinchi/water-to-unknown'        => [%w[water], %w[placeholder], []],
  # The metal-O family (the parked RInChI item re-tested once the
  # metal machinery landed): connected metal-oxygen components in
  # every role — phenoxide/acetate/silver-salt coordination bonds
  # through the identity fixtures' molfiles, oxides and salts inline.
  'rinchi/metal-kolbe-schmitt'      => [%w[metal-sodium-phenoxide-bonded co2], %w[nahco3], []],
  'rinchi/metal-silver-metathesis'  => [%w[metal-silver-nitrate-bonded nacl-ions], %w[agcl nacl-ions], []],
  'rinchi/metal-acetate-acidification' => [%w[metal-sodium-acetate-bonded hcl], %w[acetic-acid nacl-ions], []],
  'rinchi/metal-grignard-carboxylation' => [%w[metal-ethyl-magnesium-bromide co2], %w[nahco3], []],
  'rinchi/metal-oxalate-decomposition' => [%w[cuox], %w[cuo co2], []],
  'rinchi/metal-phenoxide-protonation' => [%w[metal-sodium-phenoxide-bonded hcl], %w[ethanol], []],
  'rinchi/metal-methylcopper-carboxylation' => [%w[metal-methyl-copper co2], %w[nahco3], []],
  'rinchi/metal-nickel-sulfate-isomer' => [%w[niso4], %w[niso4], []],
  'rinchi/metal-zinc-oxide-acid'    => [%w[zno hcl hcl], %w[zncl2 water], []],
  'rinchi/metal-iron-carbonate-calcination' => [%w[feco3], %w[feo co2], []]
}.freeze

# The equilibrium family: the same oracle probe under
# /force-equilibrium — the direction flag reads `/d=` regardless of
# which group sorts first.
EQUILIBRIUM_REACTIONS = {
  'rinchi/equil-water-is-water'    => [%w[water], %w[water], []],
  'rinchi/equil-esterification'    => [%w[acetic-acid ethanol], %w[ethyl-acetate water], []],
  'rinchi/equil-kolbe-schmitt'     => [%w[metal-sodium-phenoxide-bonded co2], %w[nahco3], []],
  'rinchi/equil-silver-metathesis' => [%w[metal-silver-nitrate-bonded nacl-ions], %w[agcl nacl-ions], []]
}.freeze

# The RDfile family: reaction datafiles — the `$RXN` block verbatim,
# then `$DATUM $MFMT` agent blocks whose `$DTYPE` predecessor line
# decides the block's fate (a CATALYST role stays an agent; a role
# keyword (:PRODUCT/:REACTANT/...) plus a duplicate identifier drops
# the block; a variation-number change ends the scan).
RD_REACTIONS = {
  'rinchi/rd-chlorination-no-agents' => {
    'reactants' => %w[benzene cl2], 'products' => %w[chlorobenzene hcl], 'agents' => [],
    'agent_blocks' => []
  },
  'rinchi/rd-sulfuric-catalyst' => {
    'reactants' => %w[acetic-acid ethanol], 'products' => %w[ethyl-acetate water], 'agents' => %w[sulfuric-acid],
    'agent_blocks' => [['RXN:VARIATION(1):STEPNO(1):CATALYST(1):MOL(1):MOLSTRUCTURE', 'sulfuric-acid']]
  },
  'rinchi/rd-product-repeat-drops' => {
    'reactants' => %w[acetic-acid ethanol], 'products' => %w[ethyl-acetate water], 'agents' => [],
    'agent_blocks' => [['RXN:VARIATION(1):PRODUCT(1):MOL(1):MOLSTRUCTURE', 'ethanol']]
  },
  'rinchi/rd-variation-stop' => {
    'reactants' => %w[benzene nitric-acid], 'products' => %w[nitrobenzene water],
    'agents' => %w[sulfuric-acid],
    'agent_blocks' => [
      ['RXN:VARIATION(1):STEPNO(1):CATALYST(1):MOL(1):MOLSTRUCTURE', 'sulfuric-acid'],
      ['RXN:VARIATION(2):STEPNO(1):CATALYST(1):MOL(1):MOLSTRUCTURE', 'nitric-acid']
    ]
  },
  'rinchi/rd-two-catalysts' => {
    'reactants' => %w[benzene nitric-acid], 'products' => %w[nitrobenzene water],
    'agents' => %w[sulfuric-acid water],
    'agent_blocks' => [
      ['RXN:VARIATION(1):STEPNO(1):CATALYST(1):MOL(1):MOLSTRUCTURE', 'sulfuric-acid'],
      ['RXN:VARIATION(1):STEPNO(1):CATALYST(2):MOL(1):MOLSTRUCTURE', 'water']
    ]
  }
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

def write_rdf(id, reactants, products, agent_blocks)
  out = +"$RDFILE 1\n$DATM 2026-11-03 12:00:00\n$RFMT $RIREG 42\n"
  out << write_rxn(id, reactants, products, [])
  agent_blocks.each do |(dtype, species)|
    out << "$DTYPE #{dtype}\n$DATUM $MFMT\n"
    out << molfile_for(species)
  end
  out
end

rinchi_bin = ENV.fetch('RINCHI_BIN', 'rinchi_cmdline')
inchi_bin = ENV.fetch('ASCIICHEM_INCHI_BIN', 'inchi-1')

def record_oracle(rinchi_bin, inchi_bin, id, input_text, dir)
  path = File.join(dir, 'r.in')
  File.write(path, input_text)
  output = `#{rinchi_bin} #{path} 2>&1`
  lines = output.split("\n")
  rinchi = lines.find { |l| l.start_with?('RInChI=') }
  rauxinfo = lines.find { |l| l.start_with?('RAuxInfo=') }
  long_key = lines.find { |l| l.start_with?('Long-RInChIKey=') }
  short_key = lines.find { |l| l.start_with?('Short-RInChIKey=') }
  web_key = lines.find { |l| l.start_with?('Web-RInChIKey=') }
  raise "oracle produced no RInChI for #{id}:\n#{output}" unless rinchi && rauxinfo && short_key

  [rinchi, rauxinfo,
   short_key[/^Short-RInChIKey=(\S+)/, 1],
   long_key ? long_key[/=(\S+)$/, 1] : nil,
   web_key ? web_key[/=(\S+)$/, 1] : nil]
end

def record_components(inchi_bin, species_list, dir)
  species_list.map do |species|
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
end

rows = []
REACTIONS.each do |id, (reactants, products, agents)|
  rxnfile = write_rxn(id, reactants, products, agents)
  Dir.mktmpdir do |dir|
    rinchi, rauxinfo, short_key, long_key, web_key = record_oracle(rinchi_bin, inchi_bin, id, rxnfile, dir)
    components = record_components(inchi_bin, reactants + products + agents, dir)
    rows << { 'id' => id,
              'rxnfile' => rxnfile,
              'rinchi' => rinchi,
              'rauxinfo' => rauxinfo,
              'rinchikey' => short_key,
              'longKey' => long_key,
              'webKey' => web_key,
              'components' => components }
  end
end

EQUILIBRIUM_REACTIONS.each do |id, (reactants, products, agents)|
  rxnfile = write_rxn(id, reactants, products, agents)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'r.rxn')
    File.write(path, rxnfile)
    output = `#{rinchi_bin} #{path} /force-equilibrium 2>&1`
    lines = output.split("\n")
    rinchi = lines.find { |l| l.start_with?('RInChI=') }
    rauxinfo = lines.find { |l| l.start_with?('RAuxInfo=') }
    long_key = lines.find { |l| l.start_with?('Long-RInChIKey=') }
    short_key = lines.find { |l| l.start_with?('Short-RInChIKey=') }
    web_key = lines.find { |l| l.start_with?('Web-RInChIKey=') }
    raise "oracle produced no RInChI for #{id}:\n#{output}" unless rinchi && rauxinfo && short_key
    components = record_components(inchi_bin, reactants + products + agents, dir)
    rows << { 'id' => id,
              'rxnfile' => rxnfile,
              'forceEquilibrium' => true,
              'rinchi' => rinchi,
              'rauxinfo' => rauxinfo,
              'rinchikey' => short_key[/^Short-RInChIKey=(\S+)/, 1],
              'longKey' => long_key ? long_key[/=(\S+)$/, 1] : nil,
              'webKey' => web_key ? web_key[/=(\S+)$/, 1] : nil,
              'components' => components }
  end
end

RD_REACTIONS.each do |id, spec|
  rdfile = write_rdf(id, spec['reactants'], spec['products'], spec['agent_blocks'])
  Dir.mktmpdir do |dir|
    rinchi, rauxinfo, short_key, long_key, web_key = record_oracle(rinchi_bin, inchi_bin, id, rdfile, dir)
    components = record_components(inchi_bin, spec['reactants'] + spec['products'] + spec['agents'], dir)
    rows << { 'id' => id,
              'rdfile' => rdfile,
              'rinchi' => rinchi,
              'rauxinfo' => rauxinfo,
              'rinchikey' => short_key,
              'longKey' => long_key,
              'webKey' => web_key,
              'components' => components }
  end
end
puts JSON.pretty_generate(rows)
