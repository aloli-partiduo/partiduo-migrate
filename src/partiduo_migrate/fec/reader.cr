# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  module Fec
    # Défaut d'un FEC : ligne du fichier (1 = en-tête, 0 = fichier entier),
    # zone, message.
    record Problem, line : Int32, column : String, message : String do
      def to_s(io : IO) : Nil
        if line.zero?
          io << message
        elsif column.empty?
          io << PartiduoMigrate.t("fec.problem", line: line, message: message)
        else
          io << PartiduoMigrate.t("fec.problem_column", line: line, column: column, message: message)
        end
      end
    end

    # Lecture d'un FEC en `Source::Dataset` par le lecteur commun du cœur
    # (`Partiduo::Api::Accounting.read_fec`, contrat 0.14.0), en lecture
    # *stricte* : zones de l'article A47 A-1 exigées, tabulation ou barre
    # verticale. Le lecteur reconnaît l'encodage et le séparateur, contrôle
    # les zones ligne à ligne et regroupe les lignes en écritures par
    # journal et numéro d'écriture ; ses défauts sont réunis dans
    # `problems`, dans les termes de l'outil (un fichier qui en a n'est pas
    # importé), un encodage illisible lève `Error`. Les montants bruts de
    # chaque ligne (`raw_debit`, `raw_credit`, avant le solde de la ligne)
    # sont totalisés par compte, journal et mois (`Source::Control`) pour le
    # contrôle de lecture du rapport.
    class Reader
      alias Acc = Partiduo::Api::Accounting

      # Défauts d'encodage : le fichier ne se lit pas du tout.
      ENCODING_ISSUES = %w[encoding_unknown invalid_utf8 unreadable_encoding]

      getter problems = [] of Problem
      # Avertissements qui n'empêchent pas la lecture (encodage douteux).
      getter warnings = [] of String
      getter encoding = ""
      getter separator = '\t'

      def initialize(@forced_encoding : String? = nil, @actor : Partiduo::Api::Actor = Partiduo::Api::Actor.system)
      end

      def read_file(path : String) : Source::Dataset
        read(File.read(path).to_slice, File.basename(path))
      end

      def read(bytes : Bytes, name : String = "FEC") : Source::Dataset
        dataset = Source::Dataset.new(PartiduoMigrate.t("source.fec_description", name: name))
        dataset.file_name = name
        # Lecture seule, sans la Comptabilité de l'instance (cœur 0.18.0,
        # D-MIG-024) : le contrôle `check` d'un FEC ne l'exige plus.
        view = Acc.read_fec(@actor, bytes, @forced_encoding, strict: true)
        @encoding = view.encoding
        @separator = view.separator
        view.issues.each do |issue|
          code = issue.key.split('.').last
          raise Error.new(message(code, issue, view)) if ENCODING_ISSUES.includes?(code)
          @problems << Problem.new(issue.row, column(code, issue), message(code, issue, view))
        end
        view.warnings.each { |warning| @warnings << message(warning.key.split('.').last, warning, view) }
        fill(dataset, view)
        dataset
      end

      # Modèle de la source : écritures et lignes dans l'ordre du fichier ;
      # journaux, comptes et tiers dans l'ordre de leur première ligne, avec
      # son libellé ; contrôle de lecture sur les montants bruts.
      private def fill(dataset : Source::Dataset, view : Acc::FecFileView) : Nil
        control = Source::Control.new(sides: false)
        dataset.control = control
        dataset.zero_lines = view.zero_lines
        rows = [] of {Acc::FecLineView, Acc::FecEntryView}
        view.entries.each do |item|
          entry = Source::Entry.new(item.journal_code, item.number, item.date, item.receipt, item.receipt_date,
            item.label, item.due_date)
          period = Source::Control.period_key(item.date)
          lines = item.lines
          lines.each do |line|
            entry.lines << Source::Line.new(
              account: line.account_number, account_label: line.account_label, aux: line.aux_number,
              aux_label: line.aux_label, label: line.label, debit: line.debit, credit: line.credit,
              letter: line.letter, letter_date: line.letter_date, currency_amount: line.currency_amount,
              currency_code: line.currency_code, row: line.row.to_i64,
            )
            control.add(line.account_number, item.journal_code, period, Source::Tally.new.add(line.raw_debit, line.raw_credit))
            rows << {line, item}
          end
          dataset.entries << entry
        end
        rows.sort_by!(&.[0].row).each do |(line, item)|
          dataset.journals[item.journal_code] ||= Source::Journal.new(item.journal_code, item.journal_label)
          dataset.accounts[line.account_number] ||= Source::Account.new(line.account_number, line.account_label)
          line.aux_number.try { |code| dataset.parties[code] ||= line.aux_label || "" }
        end
      end

      # Zone d'un défaut : celle du lecteur, `Debit/Credit` nommée comme
      # l'outil le fait.
      private def column(code : String, issue : Acc::FecIssueView) : String
        code == "missing_column" && issue.column == "Debit/Credit" ? PartiduoMigrate.t("fec.amount_columns") : issue.column
      end

      # Défauts que l'outil nomme sans paramètre, ou avec la seule valeur lue
      # (`value`, `name`, `encoding`) : clé `migrate.fec.*`.
      PLAIN = {"empty_file" => "empty_file", "separator" => "unknown_separator",
               "separator_strict" => "unknown_separator", "missing_column" => "missing_column",
               "empty_field" => "empty_field", "invalid_utf8" => "invalid_utf8"}
      VALUED = {"encoding_unknown" => {"unknown_encoding", "name"}, "c1_characters" => {"c1_characters", "encoding"},
                "unreadable_amount" => {"unreadable_amount", "value"}, "unreadable_direction" => {"unreadable_direction", "value"},
                "unreadable_date" => {"unreadable_date", "value"}}

      # Message d'un défaut dans les termes de l'outil (`migrate.fec.*`) ;
      # celui du cœur pour un défaut que l'outil ne nommait pas.
      private def message(code : String, issue : Acc::FecIssueView, view : Acc::FecFileView) : String
        params = issue.params
        if key = PLAIN[code]?
          return PartiduoMigrate.t("fec.#{key}")
        end
        if pair = VALUED[code]?
          key, name = pair
          return PartiduoMigrate.t("fec.#{key}", value: params[name]?, name: params[name]?, encoding: params[name]?)
        end
        case code
        when "field_count"
          PartiduoMigrate.t("fec.field_count", total: params["count"]?, expected: params["expected"]?)
        when "date_mismatch"
          PartiduoMigrate.t("fec.date_mismatch", entry: reference(view, params["entry"]?), date: params["date"]?,
            expected: params["expected"]?)
        when "unbalanced"
          PartiduoMigrate.t("fec.unbalanced", entry: reference(view, params["entry"]?),
            debit: amount(params["debit"]?), credit: amount(params["credit"]?))
        else
          issue.message
        end
      end

      # Référence d'écriture de l'outil (`OD n° 1`) pour la référence du
      # lecteur (`OD/1`).
      private def reference(view : Acc::FecFileView, value : String?) : String
        entry = view.entries.find(&.reference.==(value)) || return value.to_s
        PartiduoMigrate.t("source.entry_reference", journal: entry.journal_code, number: entry.number)
      end

      private def amount(value : String?) : String
        value.try { |text| BigDecimal.new(text) }.try { |number| Fec.format_amount(number) } || ""
      rescue InvalidBigDecimalException
        value.to_s
      end
    end
  end
end
