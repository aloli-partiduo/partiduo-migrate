# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private HEADER = PartiduoMigrate::Fec::COLUMNS.join('\t')

private def fec(*rows : String, header = HEADER) : Bytes
  ([header] + rows.to_a).join("\r\n").to_slice
end

private def row(journal = "VT", number = "1", date = "20240105", account = "411000", aux = "", label = "Facture",
                debit = "100,00", credit = "0,00", letter = "") : String
  [journal, "Ventes", number, date, account, "Clients", aux, aux.empty? ? "" : "Client #{aux}", "F1", date, label,
   debit, credit, letter, "", date, "", ""].join('\t')
end

describe PartiduoMigrate::Fec do
  it "lit les montants à virgule, à point, signés, avec séparateurs de milliers" do
    PartiduoMigrate::Fec.parse_amount("1234,56").should eq(BigDecimal.new("1234.56"))
    PartiduoMigrate::Fec.parse_amount("1 234,56").should eq(BigDecimal.new("1234.56"))
    PartiduoMigrate::Fec.parse_amount("1.234,56").should eq(BigDecimal.new("1234.56"))
    PartiduoMigrate::Fec.parse_amount("-12.5").should eq(BigDecimal.new("-12.5"))
    PartiduoMigrate::Fec.parse_amount("+0,10").should eq(BigDecimal.new("0.10"))
    PartiduoMigrate::Fec.parse_amount("").should eq(BigDecimal.new(0))
    PartiduoMigrate::Fec.parse_amount("12,3a").should be_nil
  end

  it "écrit les montants sans arrondi ni exposant" do
    PartiduoMigrate::Fec.format_amount(BigDecimal.new("1234.5")).should eq("1234,50")
    PartiduoMigrate::Fec.format_amount(BigDecimal.new("0.1234")).should eq("0,1234")
    PartiduoMigrate::Fec.format_amount(BigDecimal.new("20000")).should eq("20000,00")
    PartiduoMigrate::Fec.format_amount(BigDecimal.new("-3.10")).should eq("-3,10")
  end

  it "lit les dates AAAAMMJJ et refuse une date impossible" do
    PartiduoMigrate::Fec.parse_date("20240229").should eq(Time.utc(2024, 2, 29))
    PartiduoMigrate::Fec.parse_date("").should be_nil
    expect_raises(PartiduoMigrate::Fec::Error) { PartiduoMigrate::Fec.parse_date("20230229") }
  end

  it "reconnaît l'encodage par le lecteur commun du cœur : BOM UTF-8, UTF-8, ISO 8859-15, Windows-1252" do
    read = ->(bytes : Bytes, forced : String?) do
      reader = PartiduoMigrate::Fec::Reader.new(forced)
      dataset = reader.read(bytes)
      reader.problems.should be_empty
      {dataset.entries.first.label, reader.encoding}
    end
    text = ([HEADER] + [row(label: "Écriture €"), row(account: "706000", debit: "0,00", credit: "100,00")]).join("\r\n")
    read.call(Bytes[0xEF, 0xBB, 0xBF] + text.to_slice, nil).should eq({"Écriture €", "UTF-8"})
    read.call(text.to_slice, nil).should eq({"Écriture €", "UTF-8"})
    read.call(text.encode("ISO-8859-15"), nil).should eq({"Écriture €", "ISO-8859-15"})
    quoted = text.gsub("Écriture €", "L’écriture")
    read.call(quoted.encode("WINDOWS-1252"), nil).should eq({"L’écriture", "WINDOWS-1252"})
    read.call(quoted.encode("WINDOWS-1252"), "cp1252").should eq({"L’écriture", "WINDOWS-1252"})
    expect_raises(PartiduoMigrate::Fec::Error, "encodage inconnu") { read.call(text.to_slice, "ebcdic") }
    expect_raises(PartiduoMigrate::Fec::Error) { PartiduoMigrate::Fec::Encoding.encode("✓", "ISO-8859-15") }
  end

  it "regroupe les lignes en écritures et relève journaux, comptes et tiers" do
    reader = PartiduoMigrate::Fec::Reader.new
    dataset = reader.read(fec(row(aux: "C001", debit: "120,00", letter: "AA"),
      row(account: "706000", label: "Prestation", debit: "0,00", credit: "100,00"),
      row(account: "445710", debit: "", credit: "20,00"),
      row(account: "471000", debit: "0,00", credit: "0,00")), "123456789FEC20241231.txt")
    reader.problems.should be_empty
    reader.separator.should eq('\t')
    dataset.entries.size.should eq(1)
    entry = dataset.entries.first
    entry.lines.size.should eq(3)
    entry.balanced?.should be_true
    entry.label.should eq("Facture")
    dataset.zero_lines.should eq(1)
    dataset.parties.should eq({"C001" => "Client C001"})
    dataset.accounts.keys.sort!.should eq(%w[411000 445710 706000])
    entry.lines.first.letter.should eq("AA")
    dataset.closing_date.should eq(Time.utc(2024, 12, 31))
  end

  it "accepte la variante Montant / Sens et la barre verticale" do
    header = (PartiduoMigrate::Fec::COLUMNS - %w[Debit Credit] + %w[Montant Sens]).join('|')
    line = ->(account : String, amount : String, sens : String) do
      ["OD", "Divers", "7", "20240301", account, "Compte", "", "", "P7", "20240301", "Virement", "", "", "", "", "",
       amount, sens].join('|')
    end
    reader = PartiduoMigrate::Fec::Reader.new
    dataset = reader.read(fec(line.call("512000", "50,00", "D"), line.call("580000", "50,00", "C"), header: header))
    reader.problems.should be_empty
    reader.separator.should eq('|')
    dataset.entries.first.total_debit.should eq(BigDecimal.new(50))
  end

  it "signale les défauts ligne à ligne" do
    reader = PartiduoMigrate::Fec::Reader.new
    reader.read(fec(row(date: "20241345"), row(debit: "abc"), row(number: "2", debit: "10,00")))
    messages = reader.problems.map(&.to_s)
    messages.should contain("ligne 2, EcritureDate : date illisible : 20241345")
    messages.should contain("ligne 3, Debit : montant illisible : abc")
    messages.any?(&.includes?("VT n° 2 déséquilibrée")).should be_true
  end

  it "refuse un fichier sans les zones obligatoires ou sans séparateur reconnu" do
    reader = PartiduoMigrate::Fec::Reader.new
    reader.read("JournalCode;JournalLib\nVT;Ventes".to_slice)
    reader.problems.first.message.should contain("séparateur non reconnu")
    reader = PartiduoMigrate::Fec::Reader.new
    reader.read("JournalCode\tJournalLib\tEcritureNum\nVT\tVentes\t1".to_slice)
    reader.problems.map(&.column).should contain("CompteNum")
    reader.problems.map(&.column).should contain("Debit/Credit (ou Montant/Sens)")
  end

  it "relit à l'identique le FEC qu'il écrit" do
    dataset = demo_dataset
    bytes = IO::Memory.new
    PartiduoMigrate::Fec::Writer.new('|', "UTF-8").write(dataset, bytes)
    reader = PartiduoMigrate::Fec::Reader.new
    again = reader.read(bytes.to_slice, "732829320FEC20241231.txt")
    reader.problems.should be_empty
    again.entries.size.should eq(dataset.entries.size)
    again.lines.should eq(dataset.lines.map_with_index { |line, index| line.copy_with(row: again.lines[index].row) })
    PartiduoMigrate::Fec::Writer.file_name("732 829 320", Time.utc(2024, 12, 31)).should eq("732829320FEC20241231.txt")
  end
end
