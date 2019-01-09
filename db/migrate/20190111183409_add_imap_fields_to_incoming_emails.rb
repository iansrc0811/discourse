class AddImapFieldsToIncomingEmails < ActiveRecord::Migration[5.2]
  def change
    add_column :incoming_emails, :imap_uid_validity, :integer
    add_column :incoming_emails, :imap_uid, :integer
  end
end
