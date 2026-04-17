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
use XML::LibXML;
use POSIX qw(strftime);

use File::Basename qw( dirname );
use CGI;

use JSON           qw( encode_json decode_json to_json from_json );
use File::Basename qw( dirname );
use MIME::Base64 qw( decode_base64 encode_base64 );
use C4::Installer;
use C4::Context;
use URI::Escape;

use Koha::REST::V1;
use Koha::Plugin::Com::OpenFifth::ISO18626::Lib::API;
use Koha::Libraries;
use Koha::Patrons;
use LWP::UserAgent;
use HTTP::Request::Common;

our $VERSION = "1.0.0";

our $metadata = {
    name            => 'ISO18626',
    author          => 'Open Fifth',
    date_authored   => '2026-04-07',
    date_updated    => "2026-04-07",
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

        my $processinginstructions = {};
        foreach my $key ( keys %{$hashed} ) {
            if ( !exists $blacklist{$key} && $key !~ /^processinginstructions/ ) {
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
            if ( !exists $blacklist{$key} && $key !~ /^customerreferences/ ) {
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

    my $table = $self->get_qualified_table_name('messages');
    my $dbh   = C4::Context->dbh;

    $dbh->do("
        CREATE TABLE IF NOT EXISTS `$table` (
            `id`            INT(11) NOT NULL AUTO_INCREMENT,
            `illrequest_id` BIGINT(20) UNSIGNED NOT NULL,
            `type`          VARCHAR(64) NOT NULL,
            `content`       LONGTEXT NOT NULL,
            `timestamp`     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            FOREIGN KEY (`illrequest_id`)
                REFERENCES `illrequests` (`illrequest_id`)
                ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ") or return 0;

    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;

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

Given a search query hashref, perform a REST API search 

=cut

sub _search {
    my ( $self, $search, $other ) = @_;

    my $ua           = LWP::UserAgent->new;
    my $search_params;
    my $response;

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
    } else {
        if ( $search->{title} ) {
            push( @{ $search_params->{'-or'} }, [ { 'title' => { 'like' => '%' . $search->{title} . '%' } } ] );
        }
    }

    my $encoded_login = encode_base64( 'koha:koha' ); #TODO: Fetch from config
    my @req_headers   = (
        'Accept'        => 'application/json',
        'Authorization' => "Basic $encoded_login"
    );

    # Only fetch 3 biblios, or the search will take too long and timeout
    # TODO: Make this configurable (?)
    my $target;
    $target->{rest_api_endpoint} = 'http://localhost:8081'; #TODO: Fetch from config
    my $search_response = $ua->request(
        GET $target->{rest_api_endpoint} . "/api/v1/biblios?q=" . encode_json($search_params) . '&_per_page=3',
        @req_headers
    );

    if ( !$search_response->is_success ) {
        return 'error';
    }

    my $decoded_content = decode_json( $search_response->decoded_content );
    _add_libraries_info( $decoded_content, $target->{rest_api_endpoint}, $encoded_login );

    # if ( $other->{op} eq 'migrate' && $other->{illrequest_id} ) {
    #     my $migrated_from_request = Koha::ILL::Requests->find( $other->{illrequest_id} );
    #     my $migrated_from_attributes =
    #         { map { $_->type => $_->value } ( $migrated_from_request->extended_attributes->as_list ) };
    #     foreach my $key ( keys %$migrated_from_attributes ) {
    #         $other->{$key} = $migrated_from_attributes->{$key} unless exists $other->{$key};
    #     }
    # }

    foreach my $result ( @{$decoded_content} ) {
        push @{ $response->{results} }, $result;
    }

    # Return search results
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
                $_;
            } @{$items_response}
        ];

        my @sorted_items_response =
            sort { $a->{libraryname} cmp $b->{libraryname} } @{$final_items};

        $record->{api_items} = \@sorted_items_response;
    }
}

=head3 create

Handle the "create" flow

=cut

sub create {
    my ( $self, $params ) = @_;
    my $other       = $params->{other};
    my $stage       = $other->{stage};
    my $core_fields = _get_core_string();
    if ( !$stage || $stage eq 'init' ) {

        # First thing we want to do, is check if we're receiving
        # an OpenURL and transform it into something we can
        # understand
        if ( $other->{openurl} ) {

            # We only want to transform once
            delete $other->{openurl};
            $params = _openurl_to_ill($params);
        }

        # We simply need our template .INC to produce a form.
        return {
            cwd     => dirname(__FILE__),
            error   => 0,
            status  => '',
            message => '',
            method  => 'create',
            stage   => 'form',
            value   => $params,
            core    => $core_fields
        };
    } elsif ( $stage eq 'form' ) {

        # We may be receiving a submitted form due to an additional
        # custom field being added or deleted, or the material type
        # having been changed, so check for these things
        if ( !_can_create_request($other) ) {
            if ( defined $other->{'add_new_custom'} ) {
                my ( $custom_keys, $custom_vals ) =
                    _get_custom( $other->{'custom_key'}, $other->{'custom_value'} );
                push @{$custom_keys}, '---';
                push @{$custom_vals}, '---';
                $other->{'custom_key'}   = join "\0", @{$custom_keys};
                $other->{'custom_value'} = join "\0", @{$custom_vals};
            } elsif ( defined $other->{'custom_delete'} ) {
                my $delete_idx = $other->{'custom_delete'};
                my ( $custom_keys, $custom_vals ) =
                    _get_custom( $other->{'custom_key'}, $other->{'custom_value'} );
                splice @{$custom_keys}, $delete_idx, 1;
                splice @{$custom_vals}, $delete_idx, 1;
                $other->{'custom_key'}   = join "\0", @{$custom_keys};
                $other->{'custom_value'} = join "\0", @{$custom_vals};
            } elsif ( defined $other->{'change_type'} ) {

                # We may be receiving a submitted form due to the user having
                # changed request material type, so we just need to go straight
                # back to the form, the type has been changed in the params
                delete $other->{'change_type'};
            }
            return {
                cwd     => dirname(__FILE__),
                status  => "",
                message => "",
                error   => 0,
                value   => $params,
                method  => "create",
                stage   => "form",
                core    => $core_fields
            };
        }

        # Received completed details of form.  Validate and create request.
        my $result = {
            cwd     => dirname(__FILE__),
            status  => "",
            message => "",
            error   => 1,
            value   => {},
            method  => "create",
            stage   => "form",
            core    => $core_fields
        };
        my $failed = 0;

        my $unauthenticated_request =
            C4::Context->preference("ILLOpacUnauthenticatedRequest") && !$other->{'cardnumber'};
        if ($unauthenticated_request) {
            ( $failed, $result ) = _validate_form_params( $other, $result, $params );
            return $result if $failed;
            my $unauth_request_error = Koha::ILL::Request::unauth_request_data_error($other);
            if ($unauth_request_error) {
                $result->{status} = $unauth_request_error;
                $result->{value}  = $params;
                $failed           = 1;
            }
        } else {
            ( $failed, $result ) = _validate_form_params( $other, $result, $params );

            my ( $brw_count, $brw ) =
                _validate_borrower( $other->{'cardnumber'} );

            if ( $brw_count == 0 ) {
                $result->{status} = "invalid_borrower";
                $result->{value}  = $params;
                $failed           = 1;
            } elsif ( $brw_count > 1 ) {

                # We must select a specific borrower out of our options.
                $params->{brw}   = $brw;
                $result->{value} = $params;
                $result->{stage} = "borrowers";
                $result->{error} = 0;
                $failed          = 1;
            }
        }

        return $result if $failed;

        $self->add_request( { request => $params->{request}, other => $other } );

        my $request_details = _get_request_details( $params, $other );

        ## -> create response.
        return {
            cwd     => dirname(__FILE__),
            error   => 0,
            status  => '',
            message => '',
            method  => 'create',
            stage   => 'commit',
            next    => 'illview',
            value   => $request_details,
            core    => $core_fields
        };
    } else {

        # Invalid stage, return error.
        return {
            cwd     => dirname(__FILE__),
            error   => 1,
            status  => 'unknown_stage',
            message => '',
            method  => 'create',
            stage   => $params->{stage},
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

    Mark a request as cancelled

=cut
sub cancel {
    my ($self, $params) = @_;
    $params->{request}->status("CANCREQ")->store;

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'cancel',
        stage   => 'commit',
        next    => 'illview',
    };
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

sub add_node {
    my ( $dom, $parent, $tag, $content, $attrs ) = @_;
    
    # Create the element
    my $node = $dom->createElement($tag);
    
    # Add text if exists
    $node->appendText($content) if defined $content;
    
    # Add attributes if exists
    if ($attrs && ref $attrs eq 'HASH') {
        foreach my $key (keys %$attrs) {
            $node->setAttribute($key, $attrs->{$key});
        }
    }
    
    if (ref $parent eq 'XML::LibXML::Document') {
        $parent->setDocumentElement($node);
    } else {
        $parent->appendChild($node);
    }
    
    return $node; 
}

sub _get_attribute_map {
    my ( $self, $dom, $bib, $pub ) = @_;

    return {
        'title'  => { parent => $bib, tag => 'title' },
        'author' => { parent => $bib, tag => 'author' },
        'article_author' => { parent => $bib, tag => 'authorOfComponent' },
        'article_title' => { parent => $bib, tag => 'titleOfComponent' },
        'issue' => { parent => $bib, tag => 'issue' },
        'pages' => { parent => $bib, tag => 'pagesRequested' },
        'published_date' => { parent => $pub, tag => 'publicationDate' },
        'publisher' => { parent => $pub, tag => 'publisher' },
        'doi'    => {
            builder => sub {
                my $val = shift;
                my $id  = add_node( $dom, $bib, 'bibliographicItemId' );
                add_node( $dom, $id, 'bibliographicItemIdentifierCode', 'DOI' );
                add_node( $dom, $id, 'bibliographicItemIdentifier',     $val );
            }
        },
        'pmid' => {
            builder => sub {
                my $val = shift;
                my $id  = add_node( $dom, $bib, 'bibliographicItemId' );
                add_node( $dom, $id, 'bibliographicItemIdentifierCode', 'PMID' );
                add_node( $dom, $id, 'bibliographicItemIdentifier',     $val );
            }
        },
        'isbn' => {
            builder => sub {
                my $val = shift;
                my $id  = add_node( $dom, $bib, 'bibliographicItemId' );
                add_node( $dom, $id, 'bibliographicItemIdentifierCode', 'ISBN' );
                add_node( $dom, $id, 'bibliographicItemIdentifier',     $val );
            }
        },
        'issn' => {
            builder => sub {
                my $val = shift;
                my $id  = add_node( $dom, $bib, 'bibliographicItemId' );
                add_node( $dom, $id, 'bibliographicItemIdentifierCode', 'ISSN' );
                add_node( $dom, $id, 'bibliographicItemIdentifier',     $val );
            }
        },
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

Take a previously created submission and send it to ISO18626 supplying agency

=cut

sub create_request {
    my ( $self, $submission ) = @_;

    # 1. Setup Metadata
    my $ns_uri    = 'http://example.com/ill/request';
    my $timestamp = strftime( "%Y-%m-%d %H:%M:%S", localtime );

    my $dom  = XML::LibXML::Document->new('1.0', 'UTF-8');
    my $root = add_node($dom, $dom, 'request', undef, { xmlns => 'http://example.com/ill/request' });

    # 2. Setup Top-Level Containers
    my $header  = add_node( $dom, $root, 'header' );
    my $bib     = add_node( $dom, $root, 'bibliographicInfo' );
    my $pub     = add_node( $dom, $root, 'publicationInfo' );
    my $service = add_node( $dom, $root, 'serviceInfo' );

    my $attribute_map = $self->_get_attribute_map( $dom, $bib, $pub );

    my $attrs = $submission->illrequestattributes;

    while ( my $attr = $attrs->next ) {
        my $type  = lc( $attr->type );
        my $value = $attr->value;

        if ( exists $attribute_map->{$type} ) {
            my $map = $attribute_map->{$type};

            if ( $map->{builder} ) {
                $map->{builder}->($value);
            } else {
                add_node( $dom, $map->{parent}, $map->{tag}, $value );
            }
        }
    }

    # 3. Fill in Static/Required Header details
    add_node($dom, $header, 'requestingAgencyRequestId', $submission->illrequest_id);
    add_node($dom, $header, 'timestamp', strftime("%Y-%m-%d %H:%M:%S", localtime));

    my $agency = add_node($dom, $header, 'requestingAgencyId');
    add_node($dom, $agency, 'agencyIdType',  'ISIL');
    add_node($dom, $agency, 'agencyIdValue', 'req_agency_value');

    # --- PUBLICATION INFO SECTION ---
    # Assume $type comes from your attributes or $submission object
    my $iso_type  = $self->_map_publication_type($submission->get_type);
    add_node($dom, $pub, 'publicationType', $iso_type);

    # --- SERVICE INFO SECTION ---
    add_node( $dom, $service, 'serviceType', 'Loan' );

    # --- AUTHENTICATION SUB-SECTION ---
    my $auth = add_node($dom, $header, 'requestingAgencyAuthentication');
    add_node( $dom, $auth, 'accountId',    $self->{config}->{account_id}    // '' );
    add_node( $dom, $auth, 'securityCode', $self->{config}->{security_code} // '' );

    # 3. Prepare and send the request
    my $endpoint = $self->{config}->{url};
    unless ($endpoint) {
        my $error = 'ISO18626: No supplying agency endpoint configured.';
        warn $error;
        $submission->notesstaff($error)->status('ERROR')->store;
        return { success => 0, message => $error };
    }

    my $spec_file = dirname( $INC{'Koha/REST/V1.pm'} ) . '/../../api/v1/swagger/swagger_bundle.json';
    $spec_file    = dirname( $INC{'Koha/REST/V1.pm'} ) . '/../../api/v1/swagger/swagger.yaml'
        unless -f $spec_file;

    my $request_xml = $dom->toString(1);
    $self->_add_message(
        $submission->illrequest_id, 'request',
        encode_json( Koha::REST::V1::parse_xml( $dom->documentElement, $spec_file ) )
    );

    my $ua  = LWP::UserAgent->new;
    my $req = HTTP::Request->new( POST => $endpoint );
    $req->header( 'Content-Type' => 'application/xml' );
    $req->content($request_xml);

    my $response = $ua->request($req);

    if ( $response->is_success ) {
        my $confirmation_xml = $response->decoded_content;
        if ($confirmation_xml) {
            my $doc = eval { XML::LibXML->new()->parse_string($confirmation_xml) };
            $self->_add_message(
                $submission->illrequest_id, 'requestConfirmation',
                $doc
                    ? encode_json( Koha::REST::V1::parse_xml( $doc->documentElement, $spec_file ) )
                    : $confirmation_xml
            );
        }
        $submission->status('RequestReceived')->store;
        return { success => 1, message => '' };
    }

    my $error = sprintf(
        'ISO18626: Failed to send request to %s. Status: %s. Body: %s',
        $endpoint,
        $response->status_line,
        $response->decoded_content || 'No content'
    );
    warn $error;
    $submission->notesstaff($error)->status('ERROR')->store;
    return { success => 0, message => $error };

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
        create_api => sub { $self->create_api(@_) }
    };

    return $capabilities->{$name};
}

=head3 _can_create_request

Given the parameters we've been passed, should we create the request

=cut

sub _can_create_request {
    my ($params) = @_;
    return ( defined $params->{'stage'} ) ? 1 : 0;
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
            next_actions   => [],
            ui_method_icon => 'fa-edit',
        },
        RequestReceived => {
            prev_actions   => ['NEW'],
            id             => 'RequestReceived',
            name           => 'Place request',
            ui_method_name => 'Place request',
            method         => 'confirm',
            next_actions   => [],
            ui_method_icon => 'fa-check',
        },
        # ExpectToSupply => {
        #     prev_actions   => ['REQ'],
        #     id             => 'CIT',
        #     name           => 'Citation Verification',
        #     ui_method_name => 0,
        #     method         => 0,
        #     next_actions   => [ ],
        #     ui_method_icon => 0,
        # },
        # WillSupply => {
        #     prev_actions   => ['REQ'],
        #     id             => 'SOURCE',
        #     name           => 'Sourcing',
        #     ui_method_name => 0,
        #     method         => 0,
        #     next_actions   => [ ],
        #     ui_method_icon => 0,
        # },
        # Loaned => {
        #     prev_actions   => [],
        #     id             => 'ERROR',
        #     name           => 'Request error',
        #     ui_method_name => 0,
        #     method         => 0,
        #     next_actions   => [ 'MARK_NEW', 'COMP', 'EDITITEM', 'STANDBY', 'READY', 'MIG', 'KILL', 'CANCREQ' ],
        #     ui_method_icon => 0,
        # },
        # RetryPossible => {
        #     prev_actions   => [ 'ERROR' ],
        #     id             => 'COMP',
        #     name           => 'Order Complete',
        #     ui_method_name => 'Mark completed',
        #     method         => 'mark_completed',
        #     next_actions   => [],
        #     ui_method_icon => 'fa-check',
        # },
        # Unfilled => {
        #     prev_actions   => [ 'STANDBY', 'ERROR', 'UNAUTH' ],
        #     id             => 'CANCREQ',
        #     name           => 'Cancelled',
        #     ui_method_name => 'Mark cancelled',
        #     method         => 'cancel',
        #     next_actions   => [ 'KILL', 'MIG' ],
        #     ui_method_icon => 'fa-trash',
        # },
        # CopyCompleted => {
        #     prev_actions   => [ 'ERROR', 'STANDBY' ],
        #     id             => 'READY',
        #     name           => 'Request ready',
        #     ui_method_name => 'Mark request READY',
        #     method         => 'ready',
        #     next_actions   => [],
        #     ui_method_icon => 'fa-check',
        # },
        # LoanCompleted => {
        #     prev_actions   => [ 'NEW', 'ERROR' ],
        #     id             => 'STANDBY',
        #     name           => 'Request standing by',
        #     ui_method_name => 0,
        #     method         => 0,
        #     next_actions   => ['READY', 'MIG', 'CANCREQ'],
        #     ui_method_icon => 'fa-check',
        # },
        # CompletedWithoutReturn => {
        #     prev_actions   => [],
        #     id             => 'NEW',
        #     name           => 'New request',
        #     ui_method_name => 'New request',
        #     method         => 'create',
        #     next_actions   => [ ],
        #     ui_method_icon => 'fa-plus'
        # },
        # Cancelled => {
        #     prev_actions   => ['ERROR', 'MIG'],
        #     id             => 'MARK_NEW',
        #     name           => 'New request',
        #     ui_method_name => 'Mark request NEW',
        #     method         => 'mark_new',
        #     next_actions   => [],
        #     ui_method_icon => 'fa-refresh'
        # },
        # UNAUTH => {
        #     prev_actions   => [],
        #     id             => 'UNAUTH',
        #     name           => 'Unauthenticated',
        #     ui_method_name => 0,
        #     method         => 0,
        #     next_actions   => [ 'MARK_NEW', 'MIG', 'KILL', 'EDITITEM', 'CANCREQ' ],
        #     ui_method_icon => 0,
        # },
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

=head3 _add_message

    $self->_add_message( $illrequest_id, $type, $content );

Insert a row into the plugin messages table.

=cut

sub _add_message {
    my ( $self, $illrequest_id, $type, $content ) = @_;
    my $table = $self->get_qualified_table_name('messages');
    C4::Context->dbh->do(
        "INSERT INTO `$table` (illrequest_id, type, content, timestamp) VALUES (?, ?, ?, NOW())",
        undef, $illrequest_id, $type, $content,
    );
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
