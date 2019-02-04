module Jobs
  class PollImap < Jobs::Scheduled
    every SiteSetting.imap_polling_period_mins.minutes
    sidekiq_options retry: false

    def execute(args)
      @args = args

      Group.all.each do |group|
        mailboxes = group.mailboxes.where(sync: true)
        next if mailboxes.empty?

        begin
          imap_sync = Email::ImapSync.new(group)
        rescue Net::IMAP::Error => e
          Rails.logger.warn("Could not connect to IMAP for group #{group.name}: #{e.message}")
          return
        end

        mailboxes.each { |mailbox| imap_sync.process(mailbox) }
        imap_sync.disconnect
      end

      nil
    end
  end
end
