[% USE Koha %]
[% USE Asset %]
[% USE raw %]

[% SET koha_version = Koha.Version %]
[% cwd = whole.cwd %]

[% IF whole.error %]
  [% IF whole.status == 'missing_query' %]
    <p><em>Please Note:</em> Please enter at least a title, author, ISBN or ISSN to search.</p>
  [% ELSIF whole.status == 'invalid_borrower' %]
    <p><em>Please Note:</em> The borrower details you entered are invalid.</p>
  [% ELSIF whole.status == 'missing_branch' %]
    <p><em>Please Note:</em> Branch is a mandatory field.</p>
  [% ELSIF whole.status == 'invalid_branch' %]
    <p><em>Please Note:</em> The branch you chose is invalid.</p>
  [% ELSIF whole.message %]
    <p><em>[% whole.message %]</em></p>
  [% ELSE %]
    <p><em>Unhandled error</em></p>
  [% END %]
[% END %]

[% IF whole.stage == "commit" %]
  <p>Request created. Use 'Place request' to send the ISO18626 request to the supplying agency.</p>

[% ELSIF whole.stage == "search_form" %]
  <form class="validated" method="post" action="/cgi-bin/koha/ill/ill-requests.pl">
    [% INCLUDE 'csrf-token.inc' %]
    <input type="hidden" name="stage"   value="search_form"/>
    <input type="hidden" name="method"  value="create"/>
    <input type="hidden" name="backend" value="[% whole.value.other.backend | html %]"/>

    <fieldset class="rows">
      <legend>Search supplying agencies</legend>
      <ol>
        <li>
          <label for="title">Title:</label>
          <input type="text" id="title" name="title" value="[% whole.value.other.title | html %]"/>
        </li>
        <li>
          <label for="author">Author:</label>
          <input type="text" id="author" name="author" value="[% whole.value.other.author | html %]"/>
        </li>
        <li>
          <label for="isbn">ISBN:</label>
          <input type="text" id="isbn" name="isbn" value="[% whole.value.other.isbn | html %]"/>
        </li>
        <li>
          <label for="issn">ISSN:</label>
          <input type="text" id="issn" name="issn" value="[% whole.value.other.issn | html %]"/>
        </li>
      </ol>
    </fieldset>

    <fieldset class="rows">
      <legend>Patron options</legend>
      <ol>
        <li>
          <label class="required" for="cardnumber">Card number, username or surname:</label>
          <input class="required" required="required" type="text" id="cardnumber" name="cardnumber"
                 value="[% whole.value.other.cardnumber | html %]"/>
          <span class="required">Required</span>
        </li>
        <li>
          <label class="required" for="branchcode">Pickup branch:</label>
          <select class="required" required="required" id="branchcode" name="branchcode">
            [% FOREACH branch IN branches %]
              <option value="[% branch.branchcode | html %]"
                [% IF whole.value.other.branchcode == branch.branchcode %]selected="selected"[% END %]>
                [% branch.branchname | html %]
              </option>
            [% END %]
          </select>
          <span class="required">Required</span>
        </li>
      </ol>
    </fieldset>

    <fieldset class="action">
      <input type="submit" class="btn btn-primary" value="Search"/>
      <a class="cancel" href="/cgi-bin/koha/ill/ill-requests.pl">Cancel</a>
    </fieldset>
  </form>

[% ELSIF whole.stage == "search_results" %]

  [% IF whole.value.results && whole.value.results.size %]
    <h2>Select an item to request</h2>

    <p>
      <button type="button" class="btn btn-link" onclick="history.back()">
        <i class="fa fa-arrow-left"></i> Back to search
      </button>
    </p>

    <table id="iso18626-results-table" class="table table-bordered table-striped">
      <thead>
        <tr>
          <th>Supplying agency</th>
          <th>Title</th>
          <th>Author</th>
          <th>ISBN</th>
          <th>ISSN</th>
          <th>Available items</th>
        </tr>
      </thead>
      <tbody>
        [% FOREACH result IN whole.value.results %]
        <tr>
          <td>[% result.agency_name | html %]</td>
          <td>[% result.title | html %]</td>
          <td>[% result.author | html %]</td>
          <td>[% result.isbn | html %]</td>
          <td>[% result.issn | html %]</td>
          <td>
            [%# Build the parameters shared by every button in this row %]
            [% SET enc_backend  = whole.other.backend          | uri %]
            [% SET enc_brn      = whole.borrowernumber         | uri %]
            [% SET enc_branch   = whole.branchcode             | uri %]
            [% SET enc_title    = result.title                 | uri %]
            [% SET enc_author   = result.author                | uri %]
            [% SET enc_isbn     = result.isbn                  | uri %]
            [% SET enc_issn     = result.issn                  | uri %]
            [% SET enc_agname   = result.agency_name           | uri %]
            [% SET enc_agurl    = result.agency_url            | uri %]
            [% SET enc_agaid    = result.agency_account_id     | uri %]
            [% SET enc_agsc     = result.agency_security_code  | uri %]
            [% SET enc_supbib   = result.biblio_id             | uri %]
            [% SET base_url = "/cgi-bin/koha/ill/ill-requests.pl"
              _ "?method=create"
              _ "&amp;stage=search_results"
              _ "&amp;backend="               _ enc_backend
              _ "&amp;borrowernumber="        _ enc_brn
              _ "&amp;branchcode="            _ enc_branch
              _ "&amp;title="                 _ enc_title
              _ "&amp;author="                _ enc_author
              _ "&amp;isbn="                  _ enc_isbn
              _ "&amp;issn="                  _ enc_issn
              _ "&amp;agency_name="           _ enc_agname
              _ "&amp;agency_url="            _ enc_agurl
              _ "&amp;agency_account_id="     _ enc_agaid
              _ "&amp;agency_security_code="  _ enc_agsc
              _ "&amp;supplier_biblio_id="    _ enc_supbib
            %]
            [% IF result.api_items && result.api_items.size %]
              <table class="w-100">
                [% FOREACH item IN result.api_items %]
                  [% SET enc_item_id = item.item_id     | uri %]
                  [% SET enc_item_bc = item.external_id | uri %]
                  [% SET enc_item_cn = item.callnumber  | uri %]
                  [% SET enc_item_lb = item.libraryname | uri %]
                  [% SET item_url = base_url
                    _ "&amp;supplier_item_id="         _ enc_item_id
                    _ "&amp;supplier_item_barcode="    _ enc_item_bc
                    _ "&amp;supplier_item_callnumber=" _ enc_item_cn
                    _ "&amp;supplier_item_library="    _ enc_item_lb
                  %]
                  <tr>
                    <td class="w-100">
                      <strong>[% item.libraryname | html %]</strong>
                      [% IF item.callnumber %]
                        &mdash; [% item.callnumber | html %]
                      [% END %]
                    </td>
                    <td>
                      <a class="btn btn-sm btn-default" href="[% item_url %]">Request this item</a>
                    </td>
                  </tr>
                [% END %]
              </table>
            [% ELSE %]
              <a class="btn btn-sm btn-default" href="[% base_url %]">Request from this agency</a>
            [% END %]
          </td>
        </tr>
        [% END %]
      </tbody>
    </table>
  [% ELSE %]
    <p>No results found. <a href="javascript:history.back()">Try another search.</a></p>
  [% END %]

[% ELSIF whole.stage == "borrowers" %]
  <h2>Borrower selection</h2>
  <form method="post" action="/cgi-bin/koha/ill/ill-requests.pl">
    [% INCLUDE 'csrf-token.inc' %]
    <fieldset class="rows">
      <legend>Multiple borrowers found — please select one</legend>
      <input type="hidden" name="stage"      value="search_form"/>
      <input type="hidden" name="method"     value="create"/>
      <input type="hidden" name="backend"    value="[% whole.value.other.backend | html %]"/>
      <input type="hidden" name="branchcode" value="[% whole.value.other.branchcode | html %]"/>
      <input type="hidden" name="title"      value="[% whole.value.other.title | html %]"/>
      <input type="hidden" name="author"     value="[% whole.value.other.author | html %]"/>
      <input type="hidden" name="isbn"       value="[% whole.value.other.isbn | html %]"/>
      <input type="hidden" name="issn"       value="[% whole.value.other.issn | html %]"/>
      <ol>
        <li>
          <label class="required" for="cardnumber">Borrower:</label>
          <select name="cardnumber" id="cardnumber">
            <option value=""></option>
            [% FOREACH brw IN whole.value.brw %]
              <option value="[% brw.cardnumber | html %]">
                [% brw.firstname | html %] [% brw.surname | html %] ([% brw.cardnumber | html %])
              </option>
            [% END %]
          </select>
        </li>
      </ol>
    </fieldset>
    <fieldset class="action">
      <input type="submit" class="btn btn-primary" value="Select"/>
      <a class="cancel" href="/cgi-bin/koha/ill/ill-requests.pl">Cancel</a>
    </fieldset>
  </form>

[% ELSE %]
  <p>Unexpected stage: [% whole.stage | html %]</p>
[% END %]

[% BLOCK backend_jsinclude %]
<script>
document.addEventListener('DOMContentLoaded', function () {
    [% IF koha_version.major <= 22 && koha_version.minor < 11 %]
    $('#cardnumber').autocomplete({
        source: "/cgi-bin/koha/circ/ysearch.pl",
        minLength: 3,
        select: function (event, ui) {
            $('#cardnumber').val(ui.item.cardnumber);
            return false;
        }
    }).data('ui-autocomplete')._renderItem = function (ul, item) {
        return $('<li></li>')
            .data('ui-autocomplete-item', item)
            .append('<a>' + item.surname + ', ' + item.firstname + ' (' + item.cardnumber + ')</a>')
            .appendTo(ul);
    };
    [% ELSE %]
    if (typeof patron_autocomplete === 'function') {
        patron_autocomplete($('#cardnumber'), {
            'on-select-callback': function (event, ui) {
                $('#cardnumber').val(ui.item.cardnumber);
                return false;
            }
        });
    }
    [% END %]
});
</script>
[% END %]
