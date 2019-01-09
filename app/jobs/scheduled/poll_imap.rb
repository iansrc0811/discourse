require "net/pop"
require "net/imap"
require_dependency "imap_gmail_patch"

module Jobs
  class PollImap < Jobs::Scheduled
    every SiteSetting.imap_polling_period_mins.minutes
    sidekiq_options retry: false

    def execute(args)
      @args = args

      Group.all.each do |group|
        mailboxes = group.mailboxes.where(sync: true)
        sync_group(group, mailboxes)
      end

      nil
    end

    def sync_group(group, mailboxes)
      return if mailboxes.empty?

      begin
        imap = Net::IMAP.new(group.email_imap_server, group.email_imap_port, group.email_imap_ssl)
        imap.login(group.email_username, group.email_password)
      rescue Net::IMAP::NoResponseError => e
        Rails.logger.warn("Could not connect to IMAP for group #{group.name}: #{e.message}")
        return
      end

      is_gmail = group.email_imap_server == "imap.gmail.com"
      apply_gmail_patch(imap) if is_gmail
      mailboxes.each { |mailbox| sync_mailbox(imap, group, mailbox, is_gmail: is_gmail) }

      imap.logout
      imap.disconnect
    end

    def sync_mailbox(imap, group, mailbox, opts)

      # TODO: Server-to-client sync:
      #       - check mailbox validity
      #       - discover changes to old messages
      #       - fetch new messages
      imap.examine(mailbox.name)

      # Important operations on mailbox may invalidate mailbox and change
      # `UIDVALIDITY` attribute.
      #
      # In this case, mailbox must be resynchronized from scratch.
      uid_validity = imap.responses["UIDVALIDITY"][-1]
      if uid_validity != mailbox.uid_validity
        Rails.logger.warn("UIDVALIDITY does not match, invalidating IMAP cache and resync emails.")
        mailbox.last_seen_uid = 0
      end

      # Fetching UIDs of already synchronized and newly arrived emails.
      # Some emails may be considered newly arrived even though they have been
      # previously processed if the mailbox has been invalidated (UIDVALIDITY
      # changed).
      if mailbox.last_seen_uid == 0
        old_uids = []
        new_uids = imap.uid_search("ALL")
      else
        old_uids = imap.uid_search("UID 1:#{mailbox.last_seen_uid}")
        new_uids = imap.uid_search("UID #{mailbox.last_seen_uid + 1}:*")
      end

      if old_uids.present?
        attrs = ["UID", "FLAGS"]
        attrs << "X-GM-LABELS" if opts[:is_gmail]
        emails = imap.uid_fetch(old_uids, attrs)

        emails.each do |email|
          topic = Topic.joins(:incoming_email).find_by("incoming_emails.imap_uid_validity = ? AND incoming_emails.imap_uid = ?", uid_validity, email.attr["UID"])
          update_email(email, group, mailbox, topic) if topic
        end
      end

      if new_uids.present?
        attrs = ["UID", "FLAGS", "RFC822"]
        attrs << "X-GM-LABELS" if opts[:is_gmail]
        emails = imap.uid_fetch(new_uids, attrs)

        emails.each do |email|
          begin
            receiver = Email::Receiver.new(email.attr["RFC822"],
              destinations: [{ type: :group, obj: group }],
              uid_validity: uid_validity,
              uid: email.attr["UID"]
            )
            # TODO: If receiver has seen the email before, it will not stop and
            # not update `imap_uid_validity` and `imap_uid` fields.
            result = receiver.process!
            update_email(email, group, mailbox, result.topic) if result.is_a?(Post)

            mailbox.last_seen_uid = email.attr["UID"]
          rescue Email::Receiver::ProcessingError
          end
        end
      end

      mailbox.uid_validity = uid_validity
      mailbox.save!

      # TODO: Client-to-server sync:
      #       - sending emails using SMTP
      #       - sync labels
    end

    def update_email(email, group, mailbox, topic)
      labels = email.attr["X-GM-LABELS"]
      flags = email.attr["FLAGS"]

      # Sync archived status of topic.
      old_archived = GroupArchivedMessage.where(group_id: group.id, topic_id: topic.id).exists?
      new_archived = !labels.include?("\\Inbox") || !flags.include?(:Seen)
      if old_archived != new_archived
        if new_archived
          GroupArchivedMessage.archive!(group.id, topic)
        else
          GroupArchivedMessage.move_to_inbox!(group.id, topic)
        end
      end

      # Sync email flags and labels with topic tags.
      tags = [ to_tag(mailbox.name) ]
      flags.each { |flag| tags << to_tag(flag) }
      labels.each { |label| tags << to_tag(label) }
      tags.reject!(&:blank?)

      # TODO: Optimize tags.
      DiscourseTagging.tag_topic_by_names(topic, Guardian.new(Discourse.system_user), tags)
    end

    def to_tag(label)
      label = label.to_s
      label = label[1..-1] if label[0] == "\\"
      label = label.gsub("[Gmail]/", "")

      label if label != "All Mail" && label != "Inbox" && label != "Sent"
    end
  end
end
