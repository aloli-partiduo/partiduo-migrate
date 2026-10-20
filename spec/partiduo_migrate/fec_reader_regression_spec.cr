# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Empreinte d'un jeu de données lu : écritures et lignes dans l'ordre, journaux,
# comptes et tiers dans l'ordre de leur première ligne, lignes sans effet,
# contrôle de lecture par compte, journal et mois.
private def digest(dataset : PartiduoMigrate::Source::Dataset) : String
  io = IO::Memory.new
  dataset.entries.each do |entry|
    io << entry.journal_code << "|" << entry.number << "|" << entry.date << "|" << entry.receipt << "|" <<
      entry.receipt_date << "|" << entry.label << "|" << entry.due_date << "\n"
    entry.each_line { |line| io << "  " << line.inspect << "\n" }
  end
  io << dataset.journals.to_a.inspect << "\n" << dataset.accounts.to_a.inspect << "\n" << dataset.parties.to_a.inspect << "\n"
  io << dataset.zero_lines << "\n"
  control = dataset.control.present!
  {control.accounts, control.journals, control.periods}.each do |tallies|
    io << tallies.to_a.map { |key, tally| {key, tally.count, tally.debit, tally.credit} }.inspect << "\n"
  end
  Digest::SHA256.hexdigest(io.to_s)
end

describe "Lecteur commun du cœur : non-régression de la reprise (D-MIG-023)" do
  it "lit le FEC de démonstration exactement comme l'ancien lecteur de l'outil" do
    reader = PartiduoMigrate::Fec::Reader.new
    dataset = reader.read_file(PartiduoMigrate::SpecSupport::DEMO_FEC)
    reader.problems.should be_empty
    reader.encoding.should eq("ISO-8859-15")
    reader.separator.should eq('\t')
    # Empreinte relevée avec le lecteur propre de partiduo-migrate 0.1.2.
    digest(dataset).should eq("657ae5056c2d96123202350e7803b52796e20201c2238625c7891d561f728465")
    {dataset.entries.size, dataset.lines.size, dataset.zero_lines}.should eq({133, 354, 0})
    dataset.journals.keys.should eq(%w[O01 A01 V01 F01])
    {dataset.accounts.size, dataset.parties.size}.should eq({26, 15})
    control = dataset.control.present!
    control.journals.to_a.map { |code, tally| {code, tally.count, tally.debit, tally.credit} }.should eq([
      {"O01", 53, BigDecimal.new("74004.8"), BigDecimal.new("74004.8")},
      {"A01", 90, BigDecimal.new("23802"), BigDecimal.new("23802")},
      {"V01", 57, BigDecimal.new("36444.25"), BigDecimal.new("36444.25")},
      {"F01", 154, BigDecimal.new("112039.72"), BigDecimal.new("112039.72")},
    ])
    figures = PartiduoMigrate::Reconciliation.before(dataset, PartiduoMigrate::Mapping.new, Time.utc(2024, 12, 31))
    {figures.total.debit, figures.total.credit, figures.total.count}.should eq(
      {BigDecimal.new("246290.77"), BigDecimal.new("246290.77"), 133})
    PartiduoMigrate::Reconciliation.reading(dataset).all? { |section| section.rows.all?(&.ok?) }.should be_true
  end

  it "relit le même FEC en UTF-8 à barre verticale avec la même empreinte" do
    bytes = IO::Memory.new
    PartiduoMigrate::Fec::Writer.new('|', "UTF-8").write(demo_dataset, bytes)
    reader = PartiduoMigrate::Fec::Reader.new
    dataset = reader.read(bytes.to_slice, "732829320FEC20241231.txt")
    reader.problems.should be_empty
    {reader.encoding, reader.separator}.should eq({"UTF-8", '|'})
    digest(dataset).should eq("657ae5056c2d96123202350e7803b52796e20201c2238625c7891d561f728465")
  end

  it "lit en lecture stricte : point-virgule et zones de l'arrêté manquantes refusés" do
    reader = PartiduoMigrate::Fec::Reader.new
    reader.read("JournalCode;EcritureNum;EcritureDate;CompteNum;Debit;Credit\nOD;1;20240105;512000;10,00;\n".to_slice)
    reader.problems.map(&.to_s).should eq(["ligne 1 : séparateur non reconnu : tabulation ou barre verticale attendue"])
    reader = PartiduoMigrate::Fec::Reader.new
    reader.read("JournalCode\tEcritureNum\tEcritureDate\tCompteNum\tDebit\tCredit\nOD\t1\t20240105\t512000\t10,00\t\n".to_slice)
    reader.problems.map(&.column).should contain("JournalLib")
  end

  it "signale aussi une date de pièce illisible, et rien qu'un fichier sans écriture" do
    builder = PartiduoMigrate::SpecSupport::FecBuilder
    reader = PartiduoMigrate::Fec::Reader.new
    reader.read(builder.bytes([builder.row("OD", "1", "20241345", "512000", debit: "abc")]))
    reader.problems.map(&.column).should eq(%w[EcritureDate ValidDate PieceDate Debit])
    reader = PartiduoMigrate::Fec::Reader.new
    reader.read(builder.bytes([] of String))
    reader.problems.size.should eq(1)
    reader.problems.first.line.should eq(0)
    reader.problems.first.to_s.should_not start_with("ligne")
  end
end
