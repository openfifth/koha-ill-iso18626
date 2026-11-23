package Koha::Plugin::Com::OpenFifth::ISO18626;

# Copyright Open Fifth 2026
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;
use strict;
use warnings;

use base            qw(Koha::Plugins::Base);
use Koha::DateUtils qw( dt_from_string );
use Koha::I18N      qw(__);

use File::Basename qw( dirname );
use CGI;

use JSON           qw( encode_json decode_json to_json from_json );
use File::Basename qw( dirname );
use MIME::Base64 qw( decode_base64 encode_base64 );
use C4::Installer;
use C4::Context;
use URI;
use URI::Escape;

use Koha::Plugin::Com::OpenFifth::ISO18626::Lib::API;
use Koha::Libraries;
use Koha::Patrons;
use LWP::UserAgent;
use HTTP::Request::Common;

our $VERSION = "2.0.1";

our $metadata = {
    name            => 'ISO18626',
    author          => 'Open Fifth',
    date_authored   => '2026-04-07',
    date_updated    => "2026-11-23",
    minimum_version => '26.11.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin is a ISO18626 ILL backend'
};

sub ill_backend {
    my ( $class, $args ) = @_;
    return 'ISO18626';
}

sub name {
    return 'ISO18626';
}

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    $self->{config} = decode_json( $self->retrieve_data('iso18626_config') || '{}' );

    return $self;
}

=head3 _core_supports_requesting

    my $supported = _core_supports_requesting();

Return whether this Koha version can send ISO 18626 requests (Koha::ILL::ISO18626::Requester, bug 41091).

=cut

sub _core_supports_requesting {
    return eval { require Koha::ILL::ISO18626::Requester; require Koha::ILL::ISO18626::SupplyingAgencies; 1 } ? 1 : 0;
}

=head3 _supplying_agencies

    my @agencies = $self->_supplying_agencies;

Return the supplying agencies configured in Koha, each as a hashref with the
I<Koha::ILL::ISO18626::SupplyingAgency> (C<agency>) and this plugin's settings
for it (C<api_user>, C<api_password>, C<document_host>).

=cut

sub _supplying_agencies {
    my ($self) = @_;

    return () unless _core_supports_requesting();

    return map { $self->_supplying_agency_with_settings($_) }
        Koha::ILL::ISO18626::SupplyingAgencies->search( {}, { order_by => 'name' } )->as_list;
}

=head3 _supplying_agency_with_settings

    my $agency = $self->_supplying_agency_with_settings($supplying_agency);

Return C<$supplying_agency> and this plugin's settings for it, as a hashref.

=cut

sub _supplying_agency_with_settings {
    my ( $self, $supplying_agency ) = @_;

    my $settings = $self->{config}->{agency_settings}->{ $supplying_agency->id } // {};

    return {
        agency        => $supplying_agency,
        api_user      => $settings->{api_user}      // '',
        api_password  => $settings->{api_password}  // '',
        document_host => $settings->{document_host} // '',
    };
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );
        my $config   = $self->{config};

        # Prepare processing instructions if necessary
        my @processinginstructions = ();
        if ( $config->{processinginstructions} ) {
            my @pairs = split '_', $config->{processinginstructions};
            foreach my $pair (@pairs) {
                my ( $key, $value ) = split ":", $pair;
                push @processinginstructions, { $key => $value };
            }
        }

        # Prepare customer references if necessary
        my @customerreferences = ();
        if ( $config->{customerreferences} ) {
            my @pairs = split '_', $config->{customerreferences};
            foreach my $pair (@pairs) {
                my ( $key, $value ) = split ":", $pair;
                push @customerreferences, { $key => $value };
            }
        }

        $template->param(
            config                      => $self->{config},
            core_supports_requesting    => _core_supports_requesting(),
            supplying_agencies          => [ $self->_supplying_agencies ],
            processinginstructions      => \@processinginstructions,
            processinginstructions_size => scalar @processinginstructions,
            customerreferences          => \@customerreferences,
            customerreferences_size     => scalar @customerreferences,
            cwd                         => dirname(__FILE__)
        );
        $self->output_html( $template->output() );
    } else {
        my %blacklist = ( 'save' => 1, 'class' => 1, 'method' => 1 );
        my $hashed    = { map { $_ => ( scalar $cgi->param($_) )[0] } $cgi->param };
        my $p         = {};

        # Settings for each supplying agency configured in Koha (agency_api_user_<id>, ...)
        my $agency_settings = {};
        for my $key ( keys %{$hashed} ) {
            next unless $key =~ /^agency_(api_user|api_password|document_host)_(\d+)$/;
            $agency_settings->{$2}->{$1} = $hashed->{$key} // '';
        }
        $p->{agency_settings} = $agency_settings;

        my $processinginstructions = {};
        foreach my $key ( keys %{$hashed} ) {
            if ( !exists $blacklist{$key} && $key !~ /^processinginstructions/ && $key !~ /^agency_/ ) {
                $p->{$key} = $hashed->{$key};
            }

            # Create a hash with key and value pairs together
            # Keys are the index of the instructions, so we can keep
            # them in order, values are concatenated instruction IDs and values
            if (   $key =~ /^processinginstructions_id_(\d+)$/
                && length $hashed->{"processinginstructions_id_$1"} > 0
                && length $hashed->{"processinginstructions_value_$1"} > 0 )
            {
                $processinginstructions->{$1} =
                    $hashed->{"processinginstructions_id_$1"} . ":" . $hashed->{"processinginstructions_value_$1"};
            }
        }

        # If we have any processing instructions to store, add them to our hash
        # Note we sort the keys here so they will remain in a predictable order
        my @processing_keys = sort keys %{$processinginstructions};
        if ( scalar @processing_keys > 0 ) {
            my @processing_pairs = ();
            foreach my $processing_key (@processing_keys) {
                push @processing_pairs, $processinginstructions->{$processing_key};
            }
            $p->{processinginstructions} = join "_", @processing_pairs;
        }

        my $customerreferences = {};
        foreach my $key ( keys %{$hashed} ) {
            if ( !exists $blacklist{$key} && $key !~ /^customerreferences/ && $key !~ /^agency_/ ) {
                $p->{$key} = $hashed->{$key};
            }

            # Create a hash with key and value pairs together
            # Keys are the index of the references, so we can keep
            # them in order, values are concatenated references IDs and values
            if (   $key =~ /^customerreferences_id_(\d+)$/
                && length $hashed->{"customerreferences_id_$1"} > 0
                && length $hashed->{"customerreferences_value_$1"} > 0 )
            {
                $customerreferences->{$1} =
                    $hashed->{"customerreferences_id_$1"} . ":" . $hashed->{"customerreferences_value_$1"};
            }
        }

        $p->{use_borrower_details} =
            ( exists $hashed->{use_borrower_details} ) ? 1 : 0;

        # If we have any customer references to store, add them to our hash
        # Note we sort the keys here so they will remain in a predictable order
        my @references_keys = sort keys %{$customerreferences};
        if ( scalar @references_keys > 0 ) {
            my @references_pairs = ();
            foreach my $references_key (@references_keys) {
                push @references_pairs, $customerreferences->{$references_key};
            }
            $p->{customerreferences} = join "_", @references_pairs;
        }

        $self->store_data( { iso18626_config => scalar encode_json($p) } );
        print $cgi->redirect(
            -url => '/cgi-bin/koha/plugins/plugins-home.pl' );
        exit;
    }
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'iso18626';
}

sub install {
    my ( $self, $args ) = @_;

    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('messages');
    C4::Context->dbh->do("DROP TABLE IF EXISTS `$table`") or return 0;

    my $dt = dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    return 1;
}

sub uninstall {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('messages');
    my $dbh   = C4::Context->dbh;

    $dbh->do("DROP TABLE IF EXISTS `$table`") or return 0;

    return 1;
}

=head2 ILL availability methods

=head3 availability_check_info

Utilized if the AutoILLBackend sys pref is enabled

=cut

sub availability_check_info {
    my ( $self, $params ) = @_;

    my $endpoint = '/api/v1/contrib/' . $self->api_namespace . '/ill_backend_availability_iso18626?metadata=';

    return {
        endpoint         => $endpoint,
        name             => $metadata->{name},
    };
}

=head2 ILL backend methods

=head3 new_ill_backend

Required method utilized by I<Koha::ILL::Request> load_backend

=cut

sub new_ill_backend {
    my ( $self, $params ) = @_;

    my $api        = Koha::Plugin::Com::OpenFifth::ISO18626::Lib::API->new($VERSION);
    my $log_tt_dir = dirname(__FILE__) . '/'. name() .'/intra-includes/log/';

    $self->{_api}      = $api;
    $self->{_logger}                 = $params->{logger} if ( $params->{logger} );

    return $self;
}

=head3 _get_core_string

Return a comma delimited, quoted, string of core field keys

=cut

sub _get_core_string {
    my $core = _get_core_fields();
    return join( ",", map { '"' . $_ . '"' } keys %{$core} );
}

=head3 _search

  my $response = $self->_search($query, $other);

Searches all supplying agencies configured in Koha via their Koha REST API and
returns an aggregated results hashref with a C<results> arrayref.  Each result
is tagged with C<agency_name> and C<supplying_agency_id>.

=cut

sub _search {
    my ( $self, $search, $other ) = @_;

    my $ua       = LWP::UserAgent->new;
    my $response = { results => [] };

    for my $agency ( $self->_supplying_agencies ) {
        my $supplying_agency = $agency->{agency};

        # Derive REST API base URL from the ISO18626 endpoint URL
        ( my $base_url = $supplying_agency->endpoint ) =~ s|/api/v1/.*||;

        # Build search params
        my $search_params;
        if ( $search->{issn} ) {
            my @issn_variations = C4::Koha::GetVariationsOfISSN( $search->{issn} );
            foreach my $issn (@issn_variations) {
                push(
                    @{ $search_params->{'-or'} },
                    [ { 'issn' => { 'like' => uri_escape( '%' . $issn . '%' ) } } ]
                );
            }
        } elsif ( $search->{isbn} ) {
            my @isbn_variations = C4::Koha::GetVariationsOfISBN( $search->{isbn} );
            foreach my $isbn (@isbn_variations) {
                push(
                    @{ $search_params->{'-or'} },
                    [ { 'isbn' => { 'like' => uri_escape( '%' . $isbn . '%' ) } } ]
                );
            }
        } elsif ( $search->{title} ) {
            push @{ $search_params->{'-or'} }, [ { title => { like => '%' . $search->{title} . '%' } } ];
        } elsif ( $search->{author} ) {
            push @{ $search_params->{'-or'} }, [ { author => { like => '%' . $search->{author} . '%' } } ];
        }

        next unless $search_params;

        my @req_headers = ( 'Accept' => 'application/json' );
        my $encoded_login;
        if ( $agency->{api_user} && $agency->{api_password} ) {
            $encoded_login = encode_base64( $agency->{api_user} . ':' . $agency->{api_password}, '' );
            push @req_headers, 'Authorization' => "Basic $encoded_login";
        }

        my $search_response = $ua->request(
            GET $base_url . '/api/v1/biblios?q=' . encode_json($search_params) . '&_per_page=5',
            @req_headers
        );

        unless ( $search_response->is_success ) {
            warn sprintf(
                'ISO18626: Search failed for agency "%s" (%s): %s',
                $supplying_agency->name // '', $base_url, $search_response->status_line
            );
            next;
        }

        my $decoded = decode_json( $search_response->decoded_content );
        _add_libraries_info( $decoded, $base_url, $encoded_login // '' );

        for my $result ( @{$decoded} ) {
            $result->{agency_name}         = $supplying_agency->name // '';
            $result->{supplying_agency_id} = $supplying_agency->id;
            push @{ $response->{results} }, $result;
        }
    }

    return $response;
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
                $_->{unavailable_reasons} = _item_unavailable_reasons($_);
                $_;
            } @{$items_response}
        ];

        my @sorted_items_response =
            sort { $a->{libraryname} cmp $b->{libraryname} } @{$final_items};

        $record->{api_items} = \@sorted_items_response;
    }
}

=head3 _item_unavailable_reasons

    my $reasons = _item_unavailable_reasons($item);

Return the reasons why an item returned by the supplying agency's items API
cannot currently be lent, using the agency's own descriptions where available.

=cut

sub _item_unavailable_reasons {
    my ($item) = @_;

    my $strings = $item->{strings} // {};
    my @reasons;
    push @reasons, __('Checked out') if $item->{checked_out_date};
    push @reasons, $strings->{lost_status}->{str} || __('Lost') if $item->{lost_status};
    push @reasons, $strings->{withdrawn}->{str}   || __('Withdrawn') if $item->{withdrawn};
    push @reasons, $strings->{not_for_loan_status}->{str} || __('Not for loan')
        if $item->{effective_not_for_loan_status};
    push @reasons, $strings->{damaged_status}->{str} || __('Damaged') if $item->{damaged_status};

    return \@reasons;
}

=head3 create

Handle the "create" flow.

Stages:
  init          → show search form
  search_form   → run search across all configured agencies, show results
  search_results → user selected a result; create local ILL request in NEW status
  commit        → handled by Koha core; user then clicks "Place request" (confirm) to send ISO18626 request

=cut

sub create {
    my ( $self, $params ) = @_;
    my $other       = $params->{other};
    my $stage       = $other->{stage};
    my $core_fields = _get_core_string();
    if ( !$stage || $stage eq 'init' ) {

        if ( $other->{openurl} ) {
            delete $other->{openurl};
            $params = _openurl_to_ill($params);
        }

        return {
            cwd     => dirname(__FILE__),
            error   => 0,
            status  => '',
            message => '',
            method  => 'create',
            stage   => 'search_form',
            value   => $params,
            core    => $core_fields,
        };

    } elsif ( $stage eq 'search_form' || $stage eq 'form' ) {
        # 'form' is the stage name sent by AutoILLBackendPriority and direct callers;
        # treat it identically to 'search_form' — run the search with whatever
        # metadata is already present in $other.

        my $result = {
            cwd     => dirname(__FILE__),
            status  => '',
            message => '',
            error   => 1,
            value   => $params,
            method  => 'create',
            stage   => 'search_form',
            core    => $core_fields,
        };

        my $unauthenticated_request =
            C4::Context->preference("ILLOpacUnauthenticatedRequest") && !$other->{cardnumber};

        my ( $brw_count, $brw );
        unless ($unauthenticated_request) {
            ( $brw_count, $brw ) = _validate_borrower( $other->{cardnumber} );
            if ( $brw_count == 0 ) {
                $result->{status} = 'invalid_borrower';
                return $result;
            } elsif ( $brw_count > 1 ) {
                $params->{brw}   = $brw;
                $result->{value} = $params;
                $result->{stage} = 'borrowers';
                $result->{error} = 0;
                return $result;
            }
        }

        unless ( $other->{title} || $other->{isbn} || $other->{issn} || $other->{author} ) {
            $result->{status} = 'missing_query';
            return $result;
        }

        my $search_results = $self->_search(
            {
                title  => $other->{title},
                author => $other->{author},
                isbn   => $other->{isbn},
                issn   => $other->{issn},
            },
            $other
        );

        return {
            cwd            => dirname(__FILE__),
            error          => 0,
            status         => '',
            message        => '',
            method         => 'create',
            stage          => 'search_results',
            value          => $search_results,
            other          => $other,
            core           => $core_fields,
            borrowernumber => $brw ? $brw->borrowernumber : '',
            cardnumber     => $other->{cardnumber} // '',
            branchcode     => $other->{branchcode} // '',
        };

    } elsif ( $stage eq 'search_results' ) {

        # User has selected a result+agency — create a local ILL request (NEW status).
        # The ISO18626 request message is sent separately when the user clicks "Place request".
        my $result = {
            cwd     => dirname(__FILE__),
            status  => '',
            message => '',
            error   => 1,
            value   => $params,
            method  => 'create',
            stage   => 'search_results',
            core    => $core_fields,
        };

        unless ( $other->{branchcode} ) {
            $result->{status} = 'missing_branch';
            return $result;
        }

        my $supplying_agency_id = $other->{supplying_agency_id} // '';
        my $supplying_agency =
            _core_supports_requesting() && $supplying_agency_id =~ /^\d+$/
            ? Koha::ILL::ISO18626::SupplyingAgencies->find($supplying_agency_id)
            : undef;
        unless ($supplying_agency) {
            $result->{status} = 'invalid_agency';
            return $result;
        }

        $self->add_request( { request => $params->{request}, other => $other } );

        $params->{request}->add_or_update_attributes( {
            iso18626_supplying_agency_id => $supplying_agency->id,
            supplier_biblio_id           => $other->{supplier_biblio_id}         // '',
            supplier_item_barcode        => $other->{supplier_item_barcode}      // '',
            supplier_item_callnumber     => $other->{supplier_item_callnumber}   // '',
            supplier_item_library        => $other->{supplier_item_library}      // '',
            supplier_item_public_notes   => $other->{supplier_item_public_notes} // '',
        } );


        my $request_details = _get_request_details( $params, $other );

        return {
            cwd     => dirname(__FILE__),
            error   => 0,
            status  => '',
            message => '',
            method  => 'create',
            stage   => 'commit',
            next    => 'illview',
            value   => $request_details,
            core    => $core_fields,
        };

    } else {

        return {
            cwd     => dirname(__FILE__),
            error   => 1,
            status  => 'unknown_stage',
            message => '',
            method  => 'create',
            stage   => $stage,
            value   => {},
        };
    }
}

=head3 illview

   View and manage an ILL request

=cut

sub illview {
    my ( $self, $params ) = @_;

    return { method => "illview" };
}

=head3 cancel

    Send a Cancel requestingAgencyMessage to the supplier and set local status to CANCREQ.
    The request remains in CANCREQ until the supplier confirms via a supplyingAgencyMessage.

=cut

sub cancel {
    my ( $self, $params ) = @_;

    my $request = $params->{request};
    $self->_send_requesting_agency_message( $request, 'Cancel' );
    $request->status('CANCREQ')->store;

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'cancel',
        stage   => 'commit',
        next    => 'illview',
    };
}

=head3 mark_received

    Send a Received requestingAgencyMessage to the supplier and set local status to ItemReceived.
    ItemReceived is a local-only status — it has no ISO18626 equivalent but signals that
    the requesting library has taken custody of the item.

=cut

sub mark_received {
    my ( $self, $params ) = @_;

    my $request = $params->{request};
    $self->_send_requesting_agency_message( $request, 'Received' );
    $request->status('ItemReceived')->store;

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'mark_received',
        stage   => 'commit',
        next    => 'illview',
    };
}

=head3 retrieve_document

    Download the document from the supplier's deliveryInfo URL, attach it to the request,
    send a Received requestingAgencyMessage to the supplier and set local status to
    DocumentReceived. DocumentReceived is a local-only status — it has no ISO18626
    equivalent but signals that the document is ready to be forwarded to the patron.

=cut

sub retrieve_document {
    my ( $self, $params ) = @_;

    my $request = $params->{request};
    my %attrs   = map { $_->type => $_->value } $request->extended_attributes->as_list;

    my $error = {
        error   => 1,
        status  => 'document_retrieval_failed',
        method  => 'retrieve_document',
        stage   => 'init',
        next    => 'illview',
        value   => $params,
    };

    return { %$error, message => 'This Koha version cannot store ILL documents.' }
        unless _supports_documents();

    my $delivery_url = $attrs{delivery_url};
    return { %$error, message => 'The supplier did not send a document URL.' } unless $delivery_url;

    my $delivery_uri = URI->new($delivery_url);
    return { %$error, message => 'The document URL does not point to the supplying agency.' }
        unless ( $delivery_uri->scheme // '' ) =~ /^https?$/
        && grep { $_ eq lc $delivery_uri->host } $self->_document_hosts($request);

    my $response = LWP::UserAgent->new( protocols_allowed => [ 'http', 'https' ], max_redirect => 0 )
        ->get($delivery_url);
    return { %$error, message => 'Could not download the document: ' . $response->status_line }
        unless $response->is_success;

    my $file_name = $response->filename || 'document';
    eval { $request->add_document( { file_name => $file_name, file_content => $response->content } ) };
    return { %$error, message => 'Could not store the document: ' . $@ } if $@;

    $self->_send_requesting_agency_message( $request, 'Received' );
    $request->status('DocumentReceived')->store;

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'retrieve_document',
        stage   => 'commit',
        next    => 'illview',
    };
}

=head3 send_to_patron

    Send the ILL_DOCUMENT_READY notice, linking to the documents attached to the request,
    to the patron and set local status to DocumentSent.

=cut

sub send_to_patron {
    my ( $self, $params ) = @_;

    my $request = $params->{request};

    my $error = {
        error   => 1,
        status  => 'document_sending_failed',
        method  => 'send_to_patron',
        stage   => 'init',
        next    => 'illview',
        value   => $params,
    };

    return { %$error, message => 'This Koha version cannot store ILL documents.' }
        unless _supports_documents();

    return { %$error, message => 'The request has no documents to send.' }
        unless $request->documents->count;

    my $result = $request->send_patron_notice('ILL_DOCUMENT_READY');
    return {
        %$error,
        message => "The notice could not be sent. Check the patron's 'Interlibrary loan ready' messaging preference."
    } unless $result->{result} && @{ $result->{result}->{success} };

    $request->status('DocumentSent')->store;

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'send_to_patron',
        stage   => 'commit',
        next    => 'illview',
    };
}

=head3 _document_hosts

    my @hosts = $self->_document_hosts($request);

    Return the hosts documents for this request may be retrieved from: the host of
    the supplying agency's endpoint URL, and the agency's configured document host.

=cut

sub _document_hosts {
    my ( $self, $request ) = @_;

    return () unless _core_supports_requesting();

    my $supplying_agency = Koha::ILL::ISO18626::Requester->supplying_agency($request);
    return () unless $supplying_agency;

    my $agency     = $self->_supplying_agency_with_settings($supplying_agency);
    my $agency_uri = URI->new( $supplying_agency->endpoint );
    my @hosts      = $agency_uri->can('host') ? ( lc $agency_uri->host ) : ();
    push @hosts, lc $agency->{document_host} if $agency->{document_host};

    return grep { length } @hosts;
}

=head3 _supports_documents

    Return whether this Koha version can attach documents to ILL requests.

=cut

sub _supports_documents {
    require Koha::ILL::Request;
    return Koha::ILL::Request->can('add_document') ? 1 : 0;
}

=head3 ship_return

    Send a ShippedReturn requestingAgencyMessage to the supplier and set local status to ShippedReturn.
    ShippedReturn is a local-only status indicating the item has been dispatched back to the supplier.

=cut

sub ship_return {
    my ( $self, $params ) = @_;

    my $request = $params->{request};
    $self->_send_requesting_agency_message( $request, 'ShippedReturn' );
    $request->status('ShippedReturn')->store;

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'ship_return',
        stage   => 'commit',
        next    => 'illview',
    };
}

=head3 _send_requesting_agency_message

    $self->_send_requesting_agency_message( $request, $action );

Sends a requestingAgencyMessage with the given C<$action> (e.g. 'Cancel', 'Received',
'ShippedReturn') to the supplying agency the request was sent to, using
I<Koha::ILL::ISO18626::Requester>.

=cut

sub _send_requesting_agency_message {
    my ( $self, $request, $action ) = @_;

    my $result =
        _core_supports_requesting()
        ? Koha::ILL::ISO18626::Requester->send_requesting_agency_message(
        { illrequest => $request, action => $action } )
        : { success => 0, error => 'This Koha version cannot send ISO18626 messages' };

    unless ( $result->{success} ) {
        warn sprintf( 'ISO18626: Failed to send requestingAgencyMessage (%s): %s', $action, $result->{error} );
        return 0;
    }

    return 1;
}

=head3 edititem

Edit an item's metadata

=cut

sub edititem {
    my ( $self, $params ) = @_;

    return {
        cwd    => dirname(__FILE__),
        method => 'illlist'
    };

    #TODO Implement edititem
}

=head3 migrate

Migrate a request into or out of this backend

=cut

sub migrate {
    my ( $self, $params ) = @_;
    my $other = $params->{other};

    my $stage = $other->{stage};
    my $step  = $other->{step};

    my $fields = $self->fieldmap;

    my $request = Koha::ILL::Requests->find( $other->{illrequest_id} );

    # Record where we're migrating from, so we can log that
    my $migrating_from = $request->backend;

    $request->orderid(undef);
    $request->status('NEW') unless $request->status eq 'UNAUTH';
    $request->backend( $self->name );
    $request->updated( DateTime->now );
    $request->store;

    #TODO: Implement illrequestattributes store

    # Log that the migration took place
    if ( $self->_logger ) {
        #TODO: Implement logging of migration
    }

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'migrate',
        stage   => 'commit',
        next    => 'illview',
        value   => $params,
    };

}

=head3 _validate_metadata

Ensure the metadata we've got conforms to the order
API specification

=cut

sub _validate_metadata {
    my ( $self, $metadata ) = @_;
    return 1;
}

=head3 create_submission

Create a local submission

=cut

sub create_submission {
    my ( $self, $params ) = @_;

    my $unauthenticated_request =
        C4::Context->preference("ILLOpacUnauthenticatedRequest") && !$params->{other}->{borrowernumber};

    my $patron = Koha::Patrons->find( $params->{other}->{borrowernumber} );

    my $request = $params->{request};
    $request->borrowernumber( $patron ? $patron->borrowernumber : undef );
    $request->branchcode( $params->{other}->{branchcode} );
    $request->status( $unauthenticated_request ? 'UNAUTH' : 'NEW' );
    $request->batch_id(
        $params->{other}->{ill_batch_id} ? $params->{other}->{ill_batch_id} : $params->{other}->{batch_id} );
    $request->backend( $self->name );
    $request->placed( DateTime->now );
    $request->updated( DateTime->now );

    $request->store;

    $params->{other}->{type} = 'article';

    my $request_details = $self->_get_request_details( $params, $params->{other} );

    $request->add_or_update_attributes($request_details);

    $request->add_unauthenticated_data( $params->{other} ) if $unauthenticated_request;

    return $request;
}

=head3 _prepare_custom

=cut

sub _prepare_custom {

    # Take an arrayref of custom keys and an arrayref
    # of custom values, return a hashref of them
    my ( $keys, $values ) = @_;
    my %out = ();
    if ($keys) {
        my @k = split( "\0", $keys );
        my @v = split( "\0", $values );
        %out = map { $k[$_] => $v[$_] } 0 .. $#k;
    }
    return \%out;
}

=head3 _get_request_details

    my $request_details = _get_request_details($params, $other);

Return the illrequestattributes for a given request

=cut

sub _get_request_details {
    my ( $params, $other ) = @_;

    # Get custom key / values we've been passed
    # Prepare them for addition into the Illrequestattribute object
    my $custom =
        _prepare_custom( $other->{'custom_key'}, $other->{'custom_value'} );

    my $return = {%$custom};
    my $core   = _get_core_fields();
    foreach my $key ( keys %{$core} ) {
        $return->{$key} = $params->{other}->{$key};
    }

    return $return;
}

=head3 _get_core_fields

Return a hashref of core fields

=cut

sub _get_core_fields {
    return {
        article_author  => __('Article author'),
        article_title   => __('Article title'),
        associated_id   => __('Associated ID'),
        author          => __('Author'),
        chapter_author  => __('Chapter author'),
        chapter         => __('Chapter'),
        conference_date => __('Conference date'),
        doi             => __('DOI'),
        editor          => __('Editor'),
        eissn           => __('eISSN'),
        format          => __('Format'),
        genre           => __('Genre'),
        institution     => __('Institution'),
        isbn            => __('ISBN'),
        issn            => __('ISSN'),
        issue           => __('Issue'),
        item_date       => __('Date'),
        language        => __('Language'),
        pages           => __('Pages'),
        pagination      => __('Pagination'),
        paper_author    => __('Paper author'),
        paper_title     => __('Paper title'),
        part_edition    => __('Part / Edition'),
        publication     => __('Publication'),
        published_date  => __('Publication date'),
        published_place => __('Place of publication'),
        publisher       => __('Publisher'),
        service_type    => __('Service type'),
        pubmedid        => __('PubMed ID'),
        pmid            => __('PubMed ID'),
        sponsor         => __('Sponsor'),
        studio          => __('Studio'),
        title           => __('Title'),
        type            => __('Type'),
        venue           => __('Venue'),
        volume          => __('Volume'),
        year            => __('Year'),
    };
}

=head3 prep_submission_metadata

Given a submission's metadata, probably from a form,
but maybe as an ILL::Request::Attributes object,
and a partly constructed hashref, add any metadata that
is appropriate for this material type

=cut

sub prep_submission_metadata {
    my ( $self, $metadata, $return ) = @_;

    $return = $return //= {};

    my $metadata_hashref = {};

    if ( ref $metadata eq "Koha::ILL::Request::Attributes" ) {
        while ( my $attr = $metadata->next ) {
            $metadata_hashref->{ $attr->type } = $attr->value;
        }
    } else {
        $metadata_hashref = $metadata;
    }

    # Get our canonical field list
    my $fields = $self->fieldmap;

    # Iterate our list of fields
    foreach my $field ( keys %{$fields} ) {
        if ( $metadata_hashref->{$field}
            && length $metadata_hashref->{$field} > 0 )
        {
            $metadata_hashref->{$field} =~ s/  / /g;
            if ( $fields->{$field}->{api_max_length} ) {
                $return->{$field} = substr( $metadata_hashref->{$field}, 0, $fields->{$field}->{api_max_length} );
            } else {
                $return->{$field} = $metadata_hashref->{$field};
            }
        }
    }

    return $return;
}

=head3 submit_and_request

Creates a local submission, then uses the returned ID to create
a ISO18626 request

=cut

sub submit_and_request {
    my ( $self, $params ) = @_;

    my $submission = $self->create_submission($params);
    return $self->create_request($submission);
}

=head3 _request_body

    my $body = $self->_request_body($submission);

Return the content of the ISO 18626 request message for C<$submission>, without its header.

=cut

sub _request_body {
    my ( $self, $submission ) = @_;

    my %attrs = map { lc( $_->type ) => $_->value } $submission->extended_attributes->as_list;

    my $bibliographic_info = {};
    my %bibliographic_fields = (
        title              => 'title',
        author             => 'author',
        article_author     => 'authorOfComponent',
        article_title      => 'titleOfComponent',
        issue              => 'issue',
        pages              => 'pagesRequested',
        supplier_biblio_id => 'supplierUniqueRecordId',
    );
    for my $attr ( sort keys %bibliographic_fields ) {
        $bibliographic_info->{ $bibliographic_fields{$attr} } = $attrs{$attr} if length( $attrs{$attr} // '' );
    }

    my %item_id_codes = ( doi => 'DOI', isbn => 'ISBN', issn => 'ISSN' );
    for my $attr ( sort keys %item_id_codes ) {
        next unless length( $attrs{$attr} // '' );
        push @{ $bibliographic_info->{bibliographicItemId} },
            { bibliographicItemIdentifierCode => $item_id_codes{$attr}, bibliographicItemIdentifier => $attrs{$attr} };
    }

    if ( length( $attrs{pmid} // '' ) ) {
        push @{ $bibliographic_info->{bibliographicRecordId} },
            { bibliographicRecordIdentifierCode => 'PMID', bibliographicRecordIdentifier => $attrs{pmid} };
    }

    my $publication_info = { publicationType => $self->_map_publication_type( $submission->get_type ) };
    $publication_info->{publicationDate} = $attrs{published_date} if length( $attrs{published_date} // '' );
    $publication_info->{publisher}       = $attrs{publisher}      if length( $attrs{publisher}      // '' );

    my $service_type = $attrs{service_type} // '';
    $service_type = 'Loan' unless $service_type =~ /^(?:Loan|Copy|CopyOrLoan)$/;
    my $service_info = { serviceType => $service_type };

    # ISO 18626 has no field for the supplier's item, so it goes in the note
    my @note_parts;
    push @note_parts, "Barcode: $attrs{supplier_item_barcode}"       if $attrs{supplier_item_barcode};
    push @note_parts, "Callnumber: $attrs{supplier_item_callnumber}" if $attrs{supplier_item_callnumber};
    push @note_parts, "Library: $attrs{supplier_item_library}"       if $attrs{supplier_item_library};
    push @note_parts, "Notes: $attrs{supplier_item_public_notes}"    if $attrs{supplier_item_public_notes};
    $service_info->{note} = join( '; ', @note_parts ) if @note_parts;

    return {
        bibliographicInfo => $bibliographic_info,
        publicationInfo   => $publication_info,
        serviceInfo       => $service_info,
    };
}

=head2 _map_publication_type

Map Koha/internal item types to ISO18626 PublicationType values.

=cut

sub _map_publication_type {
    my ( $self, $type ) = @_;

    # Ensure we are comparing lowercase
    $type = lc( $type // '' );

    # Define the mapping
    my %types = (
        'article'    => 'Article',
        'book'       => 'Book',
        'chapter'    => 'Chapter',
        'journal'    => 'Journal',
        'thesis'     => 'Thesis',
        'conference' => 'ConferenceProc',
        'dvd'        => 'Movie'
    );

    return $types{$type} // 'Book';
}

=head3 create_request

Take a previously created submission and send it to its ISO18626 supplying agency

=cut

sub create_request {
    my ( $self, $submission ) = @_;

    my $supplying_agency =
        _core_supports_requesting() ? Koha::ILL::ISO18626::Requester->supplying_agency($submission) : undef;

    my $result =
          !_core_supports_requesting() ? { success => 0, error => 'This Koha version cannot send ISO18626 requests' }
        : !$supplying_agency           ? { success => 0, error => 'No supplying agency for this request' }
        :                                Koha::ILL::ISO18626::Requester->send_request(
        {
            illrequest       => $submission,
            supplying_agency => $supplying_agency,
            request          => $self->_request_body($submission),
        }
        );

    unless ( $result->{success} ) {
        my $error = 'ISO18626: ' . $result->{error};
        warn $error;
        $submission->notesstaff($error)->status('ERROR')->store;
        return { success => 0, message => $error };
    }

    $submission->status('RequestReceived')->store;
    return { success => 1, message => '' };
}

=head3 confirm

A wrapper around create_request allowing us to
provide the "confirm" method required by
the status graph

=cut

sub confirm {
    my ( $self, $params ) = @_;

    my $return = $self->create_request( $params->{request} );

    my $return_value = {
        cwd     => dirname(__FILE__),
        error   => 0,
        status  => "",
        message => "",
        method  => "create",
        stage   => "commit",
        next    => "illview",
        value   => {},
        %{$return}
    };

    return $return_value;
}

=head3 backend_metadata

Return a hashref containing canonical values from the key/value
illrequestattributes store

=cut

sub backend_metadata {
    my ( $self, $request ) = @_;

    my @ignore = (
        'requested_partners', 'type', 'type_disclaimer_value', 'type_disclaimer_date', 'unauthenticated_first_name',
        'unauthenticated_last_name', 'unauthenticated_email', 'historycheck_requests', 'copyrightclearance_confirmed'
    );

    my $attrs = $request->extended_attributes->search( { type => { '-not_in' => \@ignore } } );

    my $core_fields = _get_core_fields();
    my $metadata    = {};

    while ( my $attr = $attrs->next ) {
        my $type = $attr->type;
        my $name = $core_fields->{$type} || ucfirst($type);
        $metadata->{$name} = $attr->value;
    }

    return $metadata;
}

=head3 capabilities

    $capability = $backend->capabilities($name);

Return the sub implementing a capability selected by NAME, or 0 if that
capability is not implemented.

=cut

sub capabilities {
    my ( $self, $name ) = @_;
    my $capabilities = {

        # View and manage a request
        illview => sub { illview(@_); },

        # Migrate
        migrate => sub { $self->migrate(@_); },

        # Return whether we can create the request
        # i.e. the create form has been submitted
        can_create_request => sub { _can_create_request(@_) },

        # This is required for compatibility
        # with Koha versions prior to bug 33716
        should_display_availability => sub { _can_create_request(@_) },

        provides_backend_availability_check => sub { return 1; },

        provides_batch_requests => sub { return 1; },

        opac_unauthenticated_ill_requests => sub { return 1; },

        # We can create ILL requests with data passed from the API
        create_api => sub { $self->create_api(@_) },

        # We send ISO18626 requests to Koha's supplying agencies
        iso18626_requesting => sub { return 1; },

        # Koha passes on the supplyingAgencyMessages it receives for our requests
        iso18626_supplying_agency_message => sub { $self->_handle_supplying_agency_message(@_) },
    };

    return $capabilities->{$name};
}

=head3 _handle_supplying_agency_message

    $self->_handle_supplying_agency_message( { request => $request, message => $message } );

Update C<$request> from a supplyingAgencyMessage Koha received from its supplying agency:
set its status from C<statusInfo>, store the C<deliveryInfo> URL so the document can be
retrieved, and set the order ID to the supplying agency's request ID.

=cut

sub _handle_supplying_agency_message {
    my ( $self, $params ) = @_;

    my $request = $params->{request};
    my $message = $params->{message};

    if ( my $delivery_url = $message->{deliveryInfo}->{URL} ) {
        $request->add_or_update_attributes( { delivery_url => $delivery_url } );
    }

    if ( my $supplying_agency_request_id = $message->{header}->{supplyingAgencyRequestId} ) {
        $request->orderid($supplying_agency_request_id);
    }

    if ( my $status = $message->{statusInfo}->{status} ) {
        $request->status($status);
    }

    $request->store;

    return 1;
}

=head3 _can_create_request

Given the parameters we've been passed, should we create the request

=cut

sub _can_create_request {
    my ($params) = @_;
    return ( defined $params->{"stage"} && ( $params->{"stage"} eq "search_form" || $params->{"stage"} eq "form" ) )
        ? 1
        : 0;
}

=head3 status_graph


=cut

sub status_graph {
    return {
        EDITITEM => {
            prev_actions   => ['NEW'],
            id             => 'EDITITEM',
            name           => __('Edited item metadata'),
            ui_method_name => __('Edit item metadata'),
            method         => 'edititem',
            next_actions   => ['NEW'],
            ui_method_icon => 'fa-edit',
        },
        RequestReceived => {
            prev_actions   => ['NEW'],
            id             => 'RequestReceived',
            name           => 'Requested',
            ui_method_name => 'Place request',
            method         => 'confirm',
            next_actions   => [ 'WillSupply', 'ExpectToSupply', 'Loaned', 'CopyCompleted', 'RetryPossible', 'Unfilled', 'CANCREQ', 'Cancelled' ],
            ui_method_icon => 'fa-paper-plane',
        },

        # Local-only status (not ISO18626): set when the requesting library
        # sends a Received action to notify the supplier the item has arrived.
        ItemReceived => {
            prev_actions   => ['Loaned'],
            id             => 'ItemReceived',
            name           => 'Item received',
            ui_method_name => 'Mark as received',
            method         => 'mark_received',
            next_actions   => [ 'ShippedReturn', 'LoanCompleted', 'CompletedWithoutReturn' ],
            ui_method_icon => 'fa-box-open',
        },

        # Local-only status (not ISO18626): set when the requesting library
        # ships the item back to the supplier.
        ShippedReturn => {
            prev_actions   => ['ItemReceived'],
            id             => 'ShippedReturn',
            name           => 'Return shipped',
            ui_method_name => 'Ship return',
            method         => 'ship_return',
            next_actions   => ['LoanCompleted'],
            ui_method_icon => 'fa-truck',
        },

        # Local-only status (not ISO18626): set when the requesting library
        # retrieves the supplied document and sends a Received action to the supplier.
        DocumentReceived => {
            prev_actions   => ['CopyCompleted'],
            id             => 'DocumentReceived',
            name           => 'Document received',
            ui_method_name => 'Retrieve document',
            method         => 'retrieve_document',
            next_actions   => ['DocumentSent'],
            ui_method_icon => 'fa-file-arrow-down',
        },

        # Local-only status (not ISO18626): set when the patron is sent the
        # ILL_DOCUMENT_READY notice linking to the retrieved document.
        DocumentSent => {
            prev_actions   => ['DocumentReceived'],
            id             => 'DocumentSent',
            name           => 'Sent to user',
            ui_method_name => 'Send to patron',
            method         => 'send_to_patron',
            next_actions   => [],
            ui_method_icon => 'fa-envelope',
        },

        # Sends a Cancel requestingAgencyMessage to the supplier.
        # The request stays in CANCREQ until the supplier confirms via supplyingAgencyMessage.
        CANCREQ => {
            prev_actions   => [ 'RequestReceived', 'WillSupply', 'ExpectToSupply', 'Loaned', 'RetryPossible' ],
            id             => 'CANCREQ',
            name           => 'Cancellation requested',
            ui_method_name => 'Request cancellation',
            method         => 'cancel',
            next_actions   => ['Cancelled'],
            ui_method_icon => 'fa-times',
        },
        ERROR => {
            prev_actions   => [ ],
            id             => 'ERROR',
            name           => 'Request error',
            ui_method_name => 0,
            method         => 0,
            next_actions   => [],
            ui_method_icon => 'fa-times',
        },
    };
}

=head3 _fail

=cut

sub _fail {
    my @values = @_;
    foreach my $val (@values) {
        return 1 if ( !$val or $val eq '' );
    }
    return 0;
}

=head3 find_illrequestattribute

=cut

sub find_illrequestattribute {
    my ( $self, $attributes, $prop ) = @_;
    foreach my $attr ( @{$attributes} ) {
        if ( $attr->{type} eq $prop ) {
            return 1;
        }
    }
}

=head3 create_api

Create a local submission from data supplied via an
API call

=cut

sub create_api {
    my ( $self, $body, $request ) = @_;

    #TODO: Implement create_api

    return 1;
}

=head3 fieldmap_sorted

Return the fieldmap sorted by "order"
Note: The key of the field is added as a "key"
property of the returned hash

=cut

sub fieldmap_sorted {
    my ($self) = @_;

    my $fields = $self->fieldmap;

    my @out = ();

    foreach my $key ( sort { $fields->{$a}->{position} <=> $fields->{$b}->{position} } keys %{$fields} ) {
        my $el = $fields->{$key};
        $el->{key} = $key;
        push @out, $el;
    }

    return \@out;
}

=head3 _validate_borrower

=cut

sub _validate_borrower {

    # Perform cardnumber search.  If no results, perform surname search.
    # Return ( 0, undef ), ( 1, $brw ) or ( n, $brws )
    my ( $input, $action ) = @_;

    return ( 0, undef ) if !$input || length $input == 0;

    my $patrons = Koha::Patrons->new;
    my ( $count, $brw );
    my $query = { cardnumber => $input };
    $query = { borrowernumber => $input } if ( $action && $action eq 'search_results' );

    my $brws = $patrons->search($query);
    $count = $brws->count;
    my @criteria = qw/ surname userid firstname end /;
    while ( $count == 0 ) {
        my $criterium = shift @criteria;
        return ( 0, undef ) if ( "end" eq $criterium );
        $brws  = $patrons->search( { $criterium => $input } );
        $count = $brws->count;
    }
    if ( $count == 1 ) {
        $brw = $brws->next;
    } else {
        $brw = $brws;    # found multiple results
    }
    return ( $count, $brw );
}

=head3 _validate_form_params

    _validate_form_params( $other, $result, $params );

Validate form parameters and return the validation result

=cut

sub _validate_form_params {
    my ( $other, $result, $params ) = @_;

    my $failed = 0;
    if ( !$other->{'type'} ) {
        $result->{status} = "missing_type";
        $result->{value}  = $params;
        $failed           = 1;
    } elsif ( !$other->{'branchcode'} ) {
        $result->{status} = "missing_branch";
        $result->{value}  = $params;
        $failed           = 1;
    } elsif ( !Koha::Libraries->find( $other->{'branchcode'} ) ) {
        $result->{status} = "invalid_branch";
        $result->{value}  = $params;
        $failed           = 1;
    }

    return ( $failed, $result );
}


=head3 add_request

Add an ILL request

=cut

sub add_request {

    my ( $self, $params ) = @_;

    my $unauthenticated_request =
        C4::Context->preference("ILLOpacUnauthenticatedRequest") && !$params->{other}->{'cardnumber'};

    # ...Populate Illrequestattributes
    # generate $request_details
    my $request_details = _get_request_details( $params, $params->{other} );

    my ( $brw_count, $brw );
    ( $brw_count, $brw ) = _validate_borrower( $params->{other}->{'cardnumber'} ) unless $unauthenticated_request;

    ## Create request

    # Create bib record
    # my $biblionumber = $self->_standard_request2biblio($request_details);

    # ...Populate Illrequest
    my $request = $params->{request};
    $request->borrowernumber( $brw ? $brw->borrowernumber : undef );
    $request->branchcode( $params->{other}->{branchcode} );
    $request->status( $unauthenticated_request ? 'UNAUTH' : 'NEW' );
    $request->backend( $params->{other}->{backend} );
    $request->notesopac( $params->{other}->{notesopac} ) if exists $params->{other}->{notesopac};
    $request->placed( dt_from_string() );
    $request->updated( dt_from_string() );
    $request->batch_id(
        $params->{other}->{ill_batch_id} ? $params->{other}->{ill_batch_id} : $params->{other}->{batch_id} )
        if column_exists( 'illrequests', 'batch_id' );
    $request->store;

    $request->add_or_update_attributes($request_details);
    $request->add_unauthenticated_data( $params->{other} ) if $unauthenticated_request;

    $request->after_created;

    return $request;
}

=head3 _logger

    my $logger = $backend->_logger($logger);
    my $logger = $backend->_logger;
    Getter/Setter for our Logger object.

=cut

sub _logger {
    my ( $self, $logger ) = @_;
    $self->{_logger} = $logger if ($logger);
    return $self->{_logger};
}

1;
