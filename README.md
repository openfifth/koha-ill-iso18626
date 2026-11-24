# Koha Interlibrary Loans ISO18626 backend

This backend plugin provides the ability to create Interlibrary Loan requests using the ISO18626 protocol.

# Important

This plugin requires [Bug 37762](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=37762) and, from version 2.0.0, [Bug 41091](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=41091).
From version 2.0.3, 'Retrieve document' needs the Bug 41091 version with `Koha::ILL::ISO18626::Requester->retrieve_document`.

From version 2.0.0:

1) Supplying agencies are configured in Koha, under 'Interlibrary loans' > 'Supplying agencies'. The plugin configuration only holds the REST API credentials used to search each agency's catalogue and its document host.
2) Requests and requestingAgencyMessages are sent by Koha. Supplying agencies must send their supplyingAgencyMessages to this Koha's `/api/v1/public/ill/iso18626` endpoint.
3) ISO18626 messages are logged and shown on the request by Koha. The plugin's own messages table is dropped on upgrade.