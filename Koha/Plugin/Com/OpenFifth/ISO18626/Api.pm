package Koha::Plugin::Com::OpenFifth::ISO18626::Api;

use Modern::Perl;
use strict;
use warnings;

use File::Basename qw( dirname );
# use XML::LibXML;
# use XML::Compile;
# use XML::Compile::WSDL11;
# use XML::Compile::SOAP12;
# use XML::Compile::SOAP11;
# use XML::Compile::Transport::SOAPHTTP;
# use XML::Smart;
use JSON         qw( decode_json from_json encode_json decode_json );
use MIME::Base64 qw( decode_base64 encode_base64 );
use Encode qw( decode_utf8);
use URI::Escape  qw ( uri_unescape );

use C4::Context;
use Koha::DateUtils qw( dt_from_string );
use Koha::ILL::Requests;
use Koha::Logger;
use Koha::Patrons;
use HTTP::Request::Common;
use URI::Escape;

use LWP::UserAgent;
use Mojo::Base 'Mojolicious::Controller';
use Koha::Plugin::Com::OpenFifth::ISO18626;

sub _make_request {
    my ( $client, $req, $response_element ) = @_;

    my $credentials = _get_credentials();

    my $to_send = { %{$req}, UserCredentials => { %{$credentials} } };

    my ( $response, $trace ) = $client->($to_send);

    my $result = $response->{parameters} || {};
    my $errors = $response->{error} ? [ { message => $response->{error}->{reason} } ] : [];

    return {
        $result->{xmlData}->{_}       ? ( xmlData       => $result->{xmlData}->{_}->serialize )       : (),
        $result->{outputXmlNode}->{_} ? ( outputXmlNode => $result->{outputXmlNode}->{_}->serialize ) : (),
        $result->{xmlOutput}->{_}     ? ( xmlOutput     => $result->{xmlOutput}->{_}->serialize )     : (),
        result => $result,
        errors => $errors
    };
}

sub _get_credentials {
    my $plugin = Koha::Plugin::Com::OpenFifth::ISO18626->new();
    my $config = decode_json( $plugin->retrieve_data("iso18626_config") || {} );

    my $doc  = XML::LibXML::Document->new( '1.0', 'UTF-8' );
    my %data = (
        UserName => $doc->createCDATASection( $config->{username} ),
        Password => $doc->createCDATASection( $config->{password} ),
    );

    return \%data;
}

sub Backend_Availability {
    my $c = shift->openapi->valid_input or return;

    my $metadata = $c->validation->param('metadata') || '';
    $metadata = decode_json( decode_base64( uri_unescape($metadata) ) );

    if ( ( !$metadata->{issn} && !$metadata->{isbn} ) && !$metadata->{title} ) {
        return $c->render(
            status  => 404,
            openapi => {
                error => 'Missing title or issn/isbn',
            }
        );
    }
    my $backend = Koha::Plugin::Com::OpenFifth::ISO18626->new();
    my $response = $backend->_search($metadata);

    if ($response->{results}){
        return $c->render(
            status  => 200,
            openapi => {
                success => "Item found",
            }
        );
    }

    return $c->render(
        status  => 404,
        openapi => { error => 'Not found' }
    );

}


=head3 receive_supplying_agency_message

Receives a supplyingAgencyMessage from a supplying Koha instance (posted as XML,
converted to JSON by the core XML middleware), stores it, and responds with a
supplyingAgencyMessageConfirmation.

=cut

sub receive_supplying_agency_message {
    my $c = shift->openapi->valid_input or return;

    my $body = $c->req->body;
    my $json = eval { decode_json($body) };
    if ($@) {
        return $c->render(
            status  => 400,
            openapi => { error => 'Invalid request body' }
        );
    }

    my $msg = $json->{supplyingAgencyMessage};
    unless ($msg) {
        return $c->render(
            status  => 400,
            openapi => { error => 'Missing supplyingAgencyMessage' }
        );
    }

    my $requesting_agency_request_id = $msg->{header}{requestingAgencyRequestId};
    unless ($requesting_agency_request_id) {
        return $c->render(
            status  => 400,
            openapi => { error => 'Missing requestingAgencyRequestId in message header' }
        );
    }

    my $ill_request = Koha::ILL::Requests->find($requesting_agency_request_id);
    unless ($ill_request) {
        return $c->render(
            status  => 404,
            openapi => { error => "ILL request $requesting_agency_request_id not found" }
        );
    }

    my $plugin = Koha::Plugin::Com::OpenFifth::ISO18626->new();
    $plugin->_add_message( $ill_request->illrequest_id, 'supplyingAgencyMessage', encode_json($msg) );

    # Sync the Koha ILL request status from the incoming statusInfo
    if ( my $new_status = $msg->{statusInfo}{status} ) {
        $ill_request->status($new_status)->store;
    }

    # Store the supplier's request ID so we can echo it back in requestingAgencyMessages
    if ( my $supplying_id = $msg->{header}{supplyingAgencyRequestId} ) {
        $ill_request->add_or_update_attributes(
            { supplying_agency_request_id => $supplying_id }
        );
    }

    my $now                = dt_from_string()->strftime('%Y-%m-%dT%H:%M:%S');
    my $timestamp_received = $msg->{header}{timestamp} // $now;

    my $confirmation = {
        supplyingAgencyMessageConfirmation => {
            confirmationHeader => {
                timestamp         => $now,
                timestampReceived => $timestamp_received,
                messageStatus     => 'OK',
            },
        },
    };

    if ( my $reason = $msg->{messageInfo}{reasonForMessage} ) {
        $confirmation->{supplyingAgencyMessageConfirmation}{reasonForMessage} = $reason;
    }

    $plugin->_add_message(
        $ill_request->illrequest_id,
        'supplyingAgencyMessageConfirmation',
        encode_json($confirmation),
        'NOW() + INTERVAL 1 SECOND'
    );

    $c->res->headers->add( 'Content-Type', 'application/xml' );
    return $c->render( status => 200, openapi => $confirmation );
}

=head3 get_messages

Returns the ISO18626 messages stored in the plugin table for a given ILL request.

=cut

sub get_messages {
    my $c = shift->openapi->valid_input or return;

    my $illrequest_id = $c->validation->param('illrequest_id');

    my $ill_request = Koha::ILL::Requests->find($illrequest_id);
    unless ($ill_request) {
        return $c->render(
            status  => 404,
            openapi => { error => "ILL request $illrequest_id not found" }
        );
    }

    my $plugin = Koha::Plugin::Com::OpenFifth::ISO18626->new();
    my $table  = $plugin->get_qualified_table_name('messages');
    my $dbh    = C4::Context->dbh;

    my $messages = $dbh->selectall_arrayref(
        "SELECT id, type, content, timestamp FROM `$table` WHERE illrequest_id = ? ORDER BY timestamp DESC",
        { Slice => {} },
        $illrequest_id
    );

    return $c->render(
        status  => 200,
        openapi => $messages
    );
}

=head3 _add_libraries_info

_add_libraries_info( $decoded_content, $rest_libraries, $target->{rest_api_endpoint}, $encoded_login );

Prepares a response for the UI by fetching items information and
converting it into a human-readable format.

=cut

sub _add_libraries_info {
    my $response      = shift;
    my $base_url      = shift;
    my $encoded_login = shift;
    my $ua            = LWP::UserAgent->new;
    my $out           = [];

    foreach my $record ( @{$response} ) {

        my @items_req_headers = (
            'Accept'        => 'application/json',
            'Authorization' => "Basic $encoded_login",
            'x-koha-embed'  => '+strings'
        );

        my $items = $ua->request(
            GET sprintf(
                '%s/api/v1/biblios/%s/items?_per_page=-1',
                $base_url,
                $record->{biblio_id},
            ),
            @items_req_headers
        );

        my $items_response = decode_json( $items->decoded_content );
        if ( !$items->is_success ) {
            _warn_api_errors_for_warning(
                'Unable to fetch items information for biblio ' . $record->{biblio_id},
                $items_response
            );
            return;
        }

        my $final_items = [
            map {
                $_->{strings} = $_->{_strings};
                delete $_->{_strings};
                $_->{libraryname} = $_->{strings}->{home_library_id}->{str}
                    // $_->{strings}->{holding_library_id}->{str};
                $_;
            } @{$items_response}
        ];

        my @sorted_items_response =
            sort { $a->{libraryname} cmp $b->{libraryname} } @{$final_items};

        $record->{api_items} = \@sorted_items_response;
    }
}

1;
