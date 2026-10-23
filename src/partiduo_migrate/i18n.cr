# SPDX-License-Identifier: AGPL-3.0-or-later

require "i18n"

module PartiduoMigrate
  # Langues de l'outil : celles de Partiduo (i18n de Marten). Messages de
  # la ligne de commande, anomalies, notes et rapport sont traduits sous la
  # clé `migrate.` ; la langue est choisie par `--locale` (défaut : `fr`),
  # parmi les langues d'interface du cœur (le contrat ne les expose pas ;
  # une spec vérifie que la liste est la même que celle du cœur).
  LOCALES = %w[fr en nl de es it pt]

  # Traduction d'une clé de l'outil (`migrate.<key>`).
  def self.t(key : String, **params) : String
    I18n.t("migrate.#{key}", **params)
  end
end

# Traductions embarquées dans le binaire : l'outil ne dépend pas du
# dossier d'où il est lancé.
{% begin %}
  I18n.config.loaders << I18n::Loader::YAML.embed({{ __DIR__ + "/../../config/locales" }})
{% end %}
