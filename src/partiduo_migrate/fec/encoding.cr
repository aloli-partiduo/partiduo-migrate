# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  module Fec
    # Encodages d'un FEC *écrit* par l'outil (`export-fec`, `--out-encoding`).
    # L'arrêté admet l'ASCII et l'ISO 8859-15 ; l'UTF-8 et le Windows-1252
    # sont admis aussi. La *lecture* (encodage reconnu ou imposé par
    # `--encoding`) est celle du lecteur commun du cœur (`Reader`).
    module Encoding
      UTF8_BOM = Bytes[0xEF, 0xBB, 0xBF]

      ALIASES = {
        "utf8"         => "UTF-8",
        "utf-8"        => "UTF-8",
        "latin9"       => "ISO-8859-15",
        "iso-8859-15"  => "ISO-8859-15",
        "iso8859-15"   => "ISO-8859-15",
        "latin1"       => "ISO-8859-1",
        "iso-8859-1"   => "ISO-8859-1",
        "cp1252"       => "WINDOWS-1252",
        "windows-1252" => "WINDOWS-1252",
        "ascii"        => "ASCII",
        "utf-16"       => "UTF-16",
      }

      # Nom canonique d'un encodage demandé ; `Error` s'il est inconnu.
      def self.canonical(name : String) : String
        ALIASES[name.strip.downcase]? || raise Error.new(PartiduoMigrate.t("fec.unknown_encoding", name: name))
      end

      # Texte écrit dans l'encodage demandé ; un caractère que l'encodage ne
      # représente pas est une erreur (jamais remplacé en silence).
      def self.encode(text : String, name : String) : Bytes
        name = canonical(name)
        return text.to_slice if name == "UTF-8"
        text.encode(name)
      rescue ex : ArgumentError
        raise Error.new(PartiduoMigrate.t("fec.unrepresentable", name: name, message: ex.message.to_s))
      end
    end
  end
end
