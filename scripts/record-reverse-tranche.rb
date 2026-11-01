#!/usr/bin/env ruby
# frozen_string_literal: true

# Records the reverse-reconstruction tranche: for each selected
# fixture, the oracle's InChI2Struct reconstruction — the SDfile
# verbatim (pass 2) and the re-forward InChI of that reconstruction
# (pass 1) — as {id, inchi, sdf, forward_inchi} records in
# corpus/fixtures/reverse-reconstruction.json. Slice 1: single
# component, standard InChIs, layers formula /c /h (incl. mobile-H
# groups) /q /p /i — stereo, metals and multi-component stay out.
#
# Per-fixture oracle invocations (not a batch): a structure the oracle
# fails to reconstruct emits nothing, which would silently shift the
# batch alignment. Failures here are printed and skipped, never
# guessed.
#
#   ruby scripts/record-reverse-tranche.rb
# (ASCIICHEM_INCHI_BIN overrides the oracle path.)

require 'json'
require 'tmpdir'
require 'open3'

bin = ENV.fetch('ASCIICHEM_INCHI_BIN',
                '/tmp/inchi-clean-build/INCHI-1-SRC/INCHI_EXE/inchi-1/src/bin/inchi-1')
abort "oracle not found at #{bin}" unless File.executable?(bin)

fixtures_dir = File.expand_path('../corpus/fixtures', __dir__)

# The slice families: identity.json's named classes minus the stereo
# ones, plus a deterministic spread of the breadth sample.
stereo_classes = %w[stereo-tetrahedral stereo-ez-molfile-loss drug-stereo]
selected = []
%w[identity.json identity-breadth.json].each do |name|
  JSON.parse(File.read(File.join(fixtures_dir, name))).each_with_index do |rec, index|
    next if stereo_classes.include?(rec['structureClass'])
    if name == 'identity-breadth.json' && index % 16 != 0
      next
    end

    selected << rec
  end
end
selected.uniq! { |rec| rec['inchi'] }
puts "selected: #{selected.length}"

def oracle_reconstruct(bin, inchi, dir)
  input = File.join(dir, 'in.txt')
  aux = File.join(dir, 'aux.txt')
  log = File.join(dir, 'log.txt')
  File.write(input, inchi + "\n")
  File.delete(aux) if File.exist?(aux)
  system(bin, input, aux, log, '-InChI2Struct', '-NoLabels',
         out: File::NULL, err: File::NULL)
  return nil unless File.exist?(aux)

  aux_text = File.read(aux).strip
  return nil if aux_text.empty?

  forward_inchi = aux_text.lines.first.to_s.strip

  sdf = File.join(dir, 'out.sdf')
  File.delete(sdf) if File.exist?(sdf)
  system(bin, aux, sdf, log, '-InpAux', '-OutputSDF', '-NoLabels',
         out: File::NULL, err: File::NULL)
  return nil unless File.exist?(sdf) && !File.read(sdf).strip.empty?

  [File.read(sdf), forward_inchi]
end

records = []
skipped = []
Dir.mktmpdir do |dir|
  selected.each do |rec|
    result = oracle_reconstruct(bin, rec['inchi'], dir)
    if result
      sdf, forward_inchi = result
      records << {
        'id' => rec['id'],
        'inchi' => rec['inchi'],
        'sdf' => sdf,
        'forward_inchi' => forward_inchi
      }
    else
      skipped << rec['id']
    end
  end
end

out_path = File.join(fixtures_dir, 'reverse-reconstruction.json')
File.write(out_path, JSON.pretty_generate(records) + "\n")
puts "recorded: #{records.length} -> #{out_path}"
unless skipped.empty?
  puts "oracle could not reconstruct (skipped): #{skipped.join(', ')}"
end
