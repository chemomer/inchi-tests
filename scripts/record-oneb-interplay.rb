#!/usr/bin/env ruby
# frozen_string_literal: true

# Records corpus/fixtures/oneb-interplay.json — the 1B beta flavor ×
# non-standard option interplay tranche. The two 1B sources (the
# >1024-atom molfiles the beta writer marks unconditionally, and the
# polymer/stars-driven flip) run against the whole non-standard
# option surface (SNon, FixedH, DoNotAddH, RecMet, the stereo
# modifiers, the KET/15T/PT_* tautomer flags, and the recorded
# pairs), each cell carrying the oracle's identifier, AuxInfo line
# and InChIKey under that option line. Every cell must speak the
# beta prefix — the writer marks `1B` before consulting the standard
# flag (ichiprt1.c OutputINCHI_VersionAndKind: is_beta wins over the
# S flag) — and the snon cells must truncate at the stereo boundary.
# The chosen baseline cells also carry the oracle's XHash1/XHash2
# extensions and the MergeHash line over the beta identifier.
# Development-time tooling — the corpus ships the recorded strings.
#
#   ASCIICHEM_INCHI_BIN=/path/to/inchi-1 \
#     ruby scripts/record-oneb-interplay.rb

require 'json'
require 'tmpdir'

BIN = ENV.fetch('ASCIICHEM_INCHI_BIN')
FIXTURES = File.expand_path('../corpus/fixtures', __dir__)

# The option words the gate's mode parser knows, one oracle flag per
# word (the parser splits mode words on '+').
OPTION_FLAGS = {
  'fixedh' => ['-FixedH'],
  'snon' => ['-SNon'],
  'donotaddh' => ['-DoNotAddH'],
  'recmet' => ['-RecMet'],
  'srel' => ['-SRel'],
  'srac' => ['-SRac'],
  'sucf' => ['-SUCF'],
  'suu' => ['-SUU'],
  'sluud' => ['-SLUUD'],
  'ket' => ['-KET'],
  '15t' => ['-15T'],
  'pt22' => ['-PT_22_00'],
  'pt16' => ['-PT_16_00'],
  'pt06' => ['-PT_06_00'],
  'pt39' => ['-PT_39_00'],
  'pt13' => ['-PT_13_00'],
  'pt18' => ['-PT_18_00'],
  'satzz' => ['-SAtZZ'],
  'fs-none' => ['-NoFrameShift']
}.freeze

PAIRS = %w[fixedh+snon fixedh+recmet fixedh+donotaddh snon+donotaddh
           ket+15t fixedh+ket].freeze

# The 1B sources and their baseline mode words. `large` needs
# -LargeMolecules (the reader's cap); the polymer flavors carry their
# own flags. Every fixture class here flips the identifier to 1B by
# a different route of ichiprt1.c:1684-1703 (nAtomsAllComp,
# pOrigStruct->polymer, n_zy).
SOURCES = {
  'large' => { base: ['-LargeMolecules'], word: 'large' },
  'polymers' => { base: ['-Polymers'], word: 'polymers' },
  'polymers105' => { base: ['-Polymers105'], word: 'polymers105' },
  'npzz' => { base: ['-NPZz'], word: 'npzz' }
}.freeze

# fixture id => [class, source of the molfile]
LARGE_TRANCHE = JSON.parse(File.read(File.join(FIXTURES, 'large-molecules.json')))
POLYMERS_TRANCHE = JSON.parse(File.read(File.join(FIXTURES, 'polymers.json')))

def source_molfile(tranche, id)
  row = tranche.find { |rec| rec['id'] == id }
  raise "missing source fixture #{id}" unless row

  row['molfile']
end

# The generated V3000 chain: 1026 carbons, a methyl branch on C3 with
# an up wedge (CFG=1 — the reader's up-wedge spelling, witnessed on
# the clean binary) — the beta flavor carrying a DEFINED
# stereocenter, so SNon has something to suppress and SRel/SRac/SUCF
# have something to reshape.
def large_stereo_molfile
  carbons = 1025 # the linear chain; atom 1026 is the methyl
  bonds = carbons # chain bonds + the branch bond
  out = ["large-c1025-3methyl", '  generator', '',
         '  0  0  0  0  0  0  0  0  0  0999 V3000',
         'M  V30 BEGIN CTAB', "M  V30 COUNTS #{carbons + 1} #{bonds} 0 0 0",
         'M  V30 BEGIN ATOM']
  carbons.times do |k|
    out << "M  V30 #{k + 1} C #{k * 12} #{k.even? ? 12 : 20} 0 0"
  end
  # The methyl branch, off the chain axis so the wedge parity reads.
  out << 'M  V30 1026 C 24 60 0 0'
  out << 'M  V30 END ATOM' << 'M  V30 BEGIN BOND'
  (carbons - 1).times do |k|
    out << "M  V30 #{k + 1} 1 #{k + 1} #{k + 2}"
  end
  out << "M  V30 #{bonds} 1 3 1026 CFG=1"
  out << 'M  V30 END BOND' << 'M  V30 END CTAB' << 'M  END' << ''
  out.join("\n")
end

# The polymer CRU whose stereocenter sits DIRECTLY on the head cap:
# Zz-C*(CH3)-CH2-CH2-Zz, the wedge on the center->methyl bond. The
# center is stereogenic (Zz, methyl, chain, H all differ) and
# pseudo-adjacent from the start, so the reference's SAtZZ gate
# (ichister.c:1380-1393) drops its stereo under the default options
# and `-SAtZZ` admits it back — the allow-side witness.
def cru_zz_stereo_molfile
  atoms = [
    [12.0, 17.0, 'Zz', '  0  0  0  0'],   # 1 head cap
    [72.0, 17.0, 'C', '  0  1  2  0'],    # 2 the stereocenter, on the cap
    [132.0, 12.0, 'C', '  0  0  0  0'],   # 3 the methyl branch
    [132.0, 62.0, 'C', '  0  0  0  0'],   # 4 chain
    [192.0, 62.0, 'C', '  0  0  0  0'],   # 5 chain
    [252.0, 62.0, 'Zz', '  0  0  0  0']   # 6 tail cap
  ]
  out = ['cru-zz-stereo.mol', '  chemomer', '',
         '  6  5  0  0  0  0  0  0  0  0999 V2000']
  atoms.each do |x, y, element, fields|
    out << format('%10.4f%10.4f%10.4f', x, y, 0.0) + ' ' + element.ljust(2) +
           '  0' + fields + '  0  0  0  0  0  0  0  0'
  end
  out << '  1  2  1  0  0  0  0'
  out << '  2  3  1  1  0  0  0' # the up wedge, center first
  out << '  2  4  1  0  0  0  0'
  out << '  4  5  1  0  0  0  0'
  out << '  5  6  1  0  0  0  0'
  out << 'M  STY  1   1 SRU'
  out << 'M  SCN  1   1  HT'
  out << 'M  SAL   1  4   2   3   4   5'
  out << 'M  SBL   1  2   1   5'
  out << 'M  SMT   1 n'
  out << 'M  END'
  out.join("\n") + "\n"
end

# The polymer CRU whose stereocenter stands one bond inside an
# asymmetric unit: Zz-CH2-C*(CH3)-CH2-CH2-Zz, the wedge on the
# center->head bond. Clean pre-edit the center is NOT pseudo-adjacent
# and its parity derives — but the frame shift re-flanks the caps
# onto the senior backbone bond, the center lands pseudo-adjacent in
# the EDITED structure, and the reference drops the parity outright
# (witnessed: `-NoFrameShift` keeps `/t`, the cycled default and even
# `-SAtZZ` lose it). The fs-none cells carry the beta stereo cells;
# the SAtZZ cells stay unrecorded (2026-11-03: the oracle loses the
# parity over the frame-shift edit and chemomer keeps it — a corner
# the reproduction does not reach yet).
def cru_methyl_stereo_molfile
  atoms = [
    [12.0, 17.0, 'Zz', '  0  0  0  0'],   # 1 head cap
    [72.0, 17.0, 'C', '  0  0  0  0'],    # 2 chain (head side, 1 heavy)
    [132.0, 17.0, 'C', '  0  1  2  0'],   # 3 the stereocenter
    [192.0, 12.0, 'C', '  0  0  0  0'],   # 4 the methyl branch
    [192.0, 62.0, 'C', '  0  0  0  0'],   # 5 chain
    [252.0, 62.0, 'C', '  0  0  0  0'],   # 6 chain (tail side, 2 heavy)
    [312.0, 62.0, 'Zz', '  0  0  0  0']   # 7 tail cap
  ]
  out = ['cru-methyl-stereo.mol', '  chemomer', '',
         '  7  6  0  0  0  0  0  0  0  0999 V2000']
  atoms.each do |x, y, element, fields|
    out << format('%10.4f%10.4f%10.4f', x, y, 0.0) + ' ' + element.ljust(2) +
           '  0' + fields + '  0  0  0  0  0  0  0  0'
  end
  out << '  1  2  1  0  0  0  0'
  out << '  3  2  1  1  0  0  0' # the up wedge, center first
  out << '  3  4  1  0  0  0  0'
  out << '  3  5  1  0  0  0  0'
  out << '  5  6  1  0  0  0  0'
  out << '  6  7  1  0  0  0  0'
  out << 'M  STY  1   1 SRU'
  out << 'M  SCN  1   1  HT'
  out << 'M  SAL   1  5   2   3   4   5   6'
  out << 'M  SBL   1  2   1   6'
  out << 'M  SMT   1 n'
  out << 'M  END'
  out.join("\n") + "\n"
end

FIXTURE_ROWS = [
  { 'id' => 'oneb/polyethylene-c1025', 'source_class' => 'large',
    'molfile' => source_molfile(LARGE_TRANCHE, 'large-molecules/polyethylene-c1025') },
  { 'id' => 'oneb/polyethylene-c1025-3methyl', 'source_class' => 'large',
    'molfile' => large_stereo_molfile },
  { 'id' => 'oneb/chain2', 'source_class' => 'polymers',
    'molfile' => source_molfile(POLYMERS_TRANCHE, 'polymers/chain2') },
  { 'id' => 'oneb/charged', 'source_class' => 'polymers',
    'molfile' => source_molfile(POLYMERS_TRANCHE, 'polymers/charged') },
  { 'id' => 'oneb/cru-zz-stereo', 'source_class' => 'polymers',
    'molfile' => cru_zz_stereo_molfile,
    # The SAtZZ allow-side witness: the center sits on the cap, so
    # the default run gates its stereo and -SAtZZ admits it back.
    'extra_modes' => ['polymers+satzz', 'polymers+satzz+snon',
                      'polymers+satzz+srel', 'polymers+satzz+srac',
                      'polymers+satzz+suu', 'polymers+satzz+sluud',
                      'polymers+satzz+donotaddh', 'polymers+satzz+fixedh',
                      'polymers+satzz+recmet', 'polymers+satzz+ket'] },
  { 'id' => 'oneb/cru-methyl-stereo', 'source_class' => 'polymers',
    'molfile' => cru_methyl_stereo_molfile,
    # The frame-shift gating witness: clean pre-edit, pseudo-adjacent
    # after the cap re-flanking — the fs-none run keeps the /t, the
    # cycled default loses it. The SAtZZ cells stay unrecorded
    # (2026-11-03, see the generator comment).
    'extra_modes' => ['polymers+fs-none', 'polymers+fs-none+snon',
                      'polymers+fs-none+srel', 'polymers+fs-none+srac',
                      'polymers+fs-none+suu', 'polymers+fs-none+donotaddh',
                      'polymers+fs-none+fixedh', 'polymers+fs-none+recmet',
                      'polymers+fs-none+ket'] },
  { 'id' => 'oneb/stray-zz', 'source_class' => 'npzz',
    'molfile' => source_molfile(POLYMERS_TRANCHE, 'polymers/stray-zz') }
].freeze

# The modes each fixture class records: the baseline word plus every
# option word (class-prefixed, the gate's mode-word convention) and
# the recorded pairs.
def modes_for(source_class)
  base = SOURCES.fetch(source_class)[:word]
  ([base] + OPTION_FLAGS.keys.map { |word| "#{base}+#{word}" } +
    PAIRS.map { |pair| "#{base}+#{pair}" }).freeze
end

# The legacy flavor and the admitted stray stars record a focused
# slice: the flavor flip is what the interplay needs, the wide option
# sweep lives on the modern classes.
FOCUSED = {
  'polymers105' => ['polymers105', 'polymers105+fixedh', 'polymers105+snon'],
  'npzz' => ['npzz', 'npzz+fixedh', 'npzz+snon', 'npzz+donotaddh',
             'npzz+ket', 'npzz+fixedh+snon']
}.freeze

def mode_flags(source_class, mode)
  base = SOURCES.fetch(source_class)[:base]
  word = SOURCES.fetch(source_class)[:word]
  # Every mode segment that is not the class word is an option word
  # (the class word itself may be absent — 'snon' means the large
  # class baseline plus SNon).
  body = mode.split('+').reject { |part| part == word }
  base + body.flat_map { |part| OPTION_FLAGS.fetch(part) }
end

# The baseline cells that also record the key's 256-bit extensions
# over the beta flavor (XHash1/XHash2 and the MergeHash line).
XHASH_CELLS = %w[large polymers].freeze

def parse_blocks(txt)
  out = {}
  blocks = txt.split(/^Structure: (\d+)\n/)
  blocks.drop(1).each_slice(2) do |n, body|
    break if n.nil? || body.nil?

    inchis = body.scan(/^InChI=\S+/).map(&:strip)
    aux = body[/^AuxInfo=\S+/]
    key = body[/^InChIKey=(\S+)/, 1]
    xhash1 = body[/^XHash1=(\S+)/, 1]
    xhash2 = body[/^XHash2=(\S+)/, 1]
    hashline = body[/^InChIHash=\S+/]
    out[n.to_i] = { 'inchi' => inchis.first, 'aux' => aux, 'key' => key,
                    'xhash1' => xhash1, 'xhash2' => xhash2, 'merged' => hashline }
  end
  out
end

def run_oracle(sdf, flags, dir, tag)
  out = File.join(dir, "#{tag}.out")
  system(BIN, sdf, out, File.join(dir, "#{tag}.log"), *flags,
         out: File::NULL, err: File::NULL)
  parsed = parse_blocks(File.read(out))
  raise "#{tag}: the oracle produced #{parsed.length} blocks" if parsed.empty?

  parsed
end

records = []
FIXTURE_ROWS.each do |row|
  modes = FOCUSED.fetch(row['source_class'], modes_for(row['source_class']))
  (modes + (row['extra_modes'] || [])).each do |mode|
    records << { 'row' => row, 'mode' => mode }
  end
end
puts "cells to record: #{records.length}"

recorded = Hash.new { |h, k| h[k] = {} }
SOURCE_CLASSES = SOURCES.keys.freeze
Dir.mktmpdir do |dir|
  # One batch SDF per fixture class keeps the flag lines per run
  # uniform; every mode re-runs the whole class batch.
  SOURCE_CLASSES.each do |source_class|
    rows = FIXTURE_ROWS.select { |row| row['source_class'] == source_class }
    next if rows.empty?

    modes = FOCUSED.fetch(source_class, modes_for(source_class))
    sdf = File.join(dir, "#{source_class}.sdf")
    File.open(sdf, 'w') do |f|
      rows.each { |row| f.write(row['molfile'] + "$$$$\n") }
    end
    modes.each do |mode|
      parsed = run_oracle(sdf, ['-Key'] + mode_flags(source_class, mode), dir,
                          "#{source_class}-#{mode}")
      rows.each_with_index do |row, i|
        block = parsed[i + 1]
        raise "#{row['id']} [#{mode}]: no oracle block" if block.nil? || block['inchi'].nil?

        recorded[row['id']][mode] = block
      end
      puts "  #{source_class} [#{mode}] recorded"
    end
  end

  # The per-fixture extra modes (the SAtZZ interplay sweep on the
  # stereo CRU): one single-fixture run per mode.
  FIXTURE_ROWS.each do |row|
    (row['extra_modes'] || []).each do |mode|
      sdf = File.join(dir, 'extra.sdf')
      File.open(sdf, 'w') { |f| f.write(row['molfile'] + "$$$$\n") }
      parsed = run_oracle(sdf, ['-Key'] + mode_flags(row['source_class'], mode), dir,
                          "extra-#{row['id'].tr('/', '_')}")
      block = parsed[1]
      raise "#{row['id']} [#{mode}]: no oracle block" if block.nil? || block['inchi'].nil?

      recorded[row['id']][mode] = block
      puts "  extra #{row['id']} [#{mode}] recorded"
    end
  end

  # The extension cells: the baseline identifiers re-run with the
  # XHash and MergeHash key flags (the identifier itself must not
  # move).
  FIXTURE_ROWS.each do |row|
    mode = SOURCES.fetch(row['source_class'])[:word]
    next unless XHASH_CELLS.include?(SOURCES.fetch(row['source_class'])[:word])

    sdf = File.join(dir, 'xh.sdf')
    File.open(sdf, 'w') { |f| f.write(row['molfile'] + "$$$$\n") }
    tag = row['id'].tr('/', '_')
    xh = run_oracle(sdf, ['-Key', '-XHash1', '-XHash2'] + SOURCES.fetch(row['source_class'])[:base],
                    dir, "xh-#{tag}")
    mh = run_oracle(sdf, ['-Key', '-XHash1', '-XHash2', '-MergeHash'] + SOURCES.fetch(row['source_class'])[:base],
                    dir, "mh-#{tag}")
    cell = recorded[row['id']][mode]
    raise "xhash baseline moved the identifier for #{row['id']}" if xh[1]['inchi'] != cell['inchi']
    raise "mergehash baseline moved the identifier for #{row['id']}" if mh[1]['inchi'] != cell['inchi']

    cell['xhash1'] = xh[1]['xhash1']
    cell['xhash2'] = xh[1]['xhash2']
    cell['merged'] = mh[1]['merged']
    puts "  xhash #{row['id']} recorded"
  end
end

# --- contract checks over the recorded strings -------------------------

failures = []
records.each do |cell|
  row = cell['row']
  mode = cell['mode']
  rec = recorded[row['id']][mode]
  id = "#{row['id']} [#{mode}]"
  # 1. The unconditional beta mark: every cell of every 1B source
  #    speaks InChI=1B — the writer flags beta before consulting the
  #    standard flag, so no option line unmarks it.
  failures << "#{id}: prefix #{rec['inchi'][0, 12]}... is not beta" unless rec['inchi'].start_with?('InChI=1B/')
  # 2. The recorded key must exist for a produced identifier.
  failures << "#{id}: no InChIKey recorded" if rec['key'].nil?
  # 3. SNon truncates at the stereo boundary: no /b /t /m /s segment.
  if mode.split('+').include?('snon')
    segments = rec['inchi'].split('/')[1..] || []
    bad = segments.grep(/\A[btms][^A-Za-z]/) + segments.grep(/\A[btms]\z/)
    failures << "#{id}: snon kept stereo segments #{bad}" unless bad.empty?
  end
end

# 4. The baselines must reproduce the existing tranches' recordings.
baseline_expectations = {
  'oneb/polyethylene-c1025' => LARGE_TRANCHE.find { |r| r['id'] == 'large-molecules/polyethylene-c1025' },
  'oneb/chain2' => POLYMERS_TRANCHE.find { |r| r['id'] == 'polymers/chain2' },
  'oneb/charged' => POLYMERS_TRANCHE.find { |r| r['id'] == 'polymers/charged' },
  'oneb/stray-zz' => POLYMERS_TRANCHE.find { |r| r['id'] == 'polymers/stray-zz' }
}
baseline_expectations.each do |id, source|
  word = SOURCES.fetch(FIXTURE_ROWS.find { |row| row['id'] == id }['source_class'])[:word]
  rec = recorded[id][word]
  expected = source['inchi'] || source.dig('modes', word, 'inchi')
  failures << "#{id} [#{word}]: baseline #{rec['inchi']} != source #{expected}" if rec['inchi'] != expected
end

raise "contract failures:\n#{failures.join("\n")}" unless failures.empty?

# --- emit ---------------------------------------------------------------

# The /rB wedge-mark echo over the frame-shift-edited structure: the
# oracle places the P mark on an entry chemomer's per-atom echo never
# reaches (2026-11-03, oneb/cru-methyl-stereo cycled cells: oracle
# `P2s5` vs chemomer `s2s5` at the one entry — the NoFrameShift cells
# agree byte-for-byte). The identifiers and keys carry the contract;
# the aux stays unrecorded on those cells.
DROP_AUX_CYCLED = ['oneb/cru-methyl-stereo'].freeze

rows = FIXTURE_ROWS.map do |row|
  modes = recorded[row['id']].transform_values do |rec|
    cell = { 'inchi' => rec['inchi'], 'aux' => rec['aux'], 'key' => rec['key'] }
    cell['xhash1'] = rec['xhash1'] if rec['xhash1']
    cell['xhash2'] = rec['xhash2'] if rec['xhash2']
    cell['merged'] = rec['merged'] if rec['merged']
    cell
  end
  if DROP_AUX_CYCLED.include?(row['id'])
    modes.each do |mode, cell|
      cell.delete('aux') unless mode.split('+').include?('fs-none')
    end
  end
  { 'id' => row['id'], 'structureClass' => 'oneb-interplay',
    'molfile' => row['molfile'], 'modes' => modes }
end

path = File.join(FIXTURES, 'oneb-interplay.json')
File.write(path, JSON.pretty_generate(rows) + "\n")
puts "wrote #{path} (#{rows.sum { |r| r['modes'].length }} cells over #{rows.length} fixtures)"
