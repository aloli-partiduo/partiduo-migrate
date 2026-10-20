# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "yaml"

private INTERPOLATION = /%\{[^}]*\}/
private DIR           = File.join(PartiduoMigrate::SpecSupport::ROOT, "config", "locales")

private def leaves(node : YAML::Any, prefix : String = "", into = {} of String => String) : Hash(String, String)
  if hash = node.as_h?
    hash.each { |key, value| leaves(value, prefix.empty? ? key.to_s : "#{prefix}.#{key}", into) }
  else
    into[prefix] = node.as_a?.try(&.map(&.to_s).join("\n")) || node.to_s
  end
  into
end

private def values(locale : String) : Hash(String, String)
  leaves(YAML.parse(File.read(File.join(DIR, "#{locale}.yml")))[locale])
end

# Traductions de l'outil (ADR-005 D7) : messages de la ligne de commande,
# anomalies, notes et rapport, en fr, en et nl.
describe "Traductions de partiduo-migrate (fr, en, nl)" do
  it "a les mêmes clés, aux mêmes interpolations, dans chaque langue" do
    reference = values("fr")
    failures = %w[en nl].flat_map do |locale|
      other = values(locale)
      (reference.keys - other.keys).map { |key| "#{locale} n'a pas #{key}" } +
        (other.keys - reference.keys).map { |key| "#{locale} a #{key}, absente en fr" } +
        (reference.keys & other.keys).compact_map do |key|
          expected = reference[key].scan(INTERPOLATION).map(&.[0]).to_set
          "#{locale}.#{key} n'interpole pas #{expected.to_a.sort.join(" ")}" unless other[key].scan(INTERPOLATION).map(&.[0]).to_set == expected
        end
    end
    failures.should eq([] of String)
  end

  it "traduit dans chaque langue toute clé citée par le code (PartiduoMigrate.t, I18n.t, erreurs)" do
    cited = Dir.glob(File.join(PartiduoMigrate::SpecSupport::ROOT, "src", "**", "*.cr")).flat_map do |path|
      File.read_lines(path).reject(&.lstrip.starts_with?('#')).flat_map do |line|
        line.scan(/PartiduoMigrate\.t\(\s*"([a-z0-9_.]+)"/).map { |match| "migrate.#{match[1]}" } +
          line.scan(/(?:I18n\.t!?\(\s*|FieldError\.\w+\(\s*)"(migrate\.[a-z0-9_.]+)"/).map(&.[1])
      end
    end.uniq!
    cited.size.should be > 20
    known = PartiduoMigrate::LOCALES.to_h do |locale|
      leaves = values(locale).keys.map { |key| "migrate.#{key.lchop("migrate.")}" }
      nodes = leaves.flat_map { |key| parts = key.split('.'); (1..parts.size).map { |size| parts.first(size).join('.') } }
      {locale, nodes.to_set}
    end
    cited.flat_map { |key| known.compact_map { |locale, keys| "#{locale}:#{key}" unless keys.includes?(key) } }.sort!
      .should eq([] of String)
  end
end
