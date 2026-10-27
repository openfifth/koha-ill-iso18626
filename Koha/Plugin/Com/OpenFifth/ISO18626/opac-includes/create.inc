[% USE Koha %]

[% cwd = whole.cwd %]

[% IF whole.error %]
  [% IF whole.status == 'missing_query' %]
    <div class="alert alert-warning"><strong>Please note:</strong> Please enter at least a title, author, ISBN or ISSN to search.</div>
  [% ELSIF whole.status == 'invalid_borrower' %]
    <div class="alert alert-warning"><strong>Please note:</strong> The patron details you entered are invalid.</div>
  [% ELSIF whole.status == 'missing_branch' %]
    <div class="alert alert-warning"><strong>Please note:</strong> Library is a mandatory field.</div>
  [% ELSIF whole.status == 'invalid_agency' %]
    <div class="alert alert-warning"><strong>Please note:</strong> The supplying agency you chose is not configured.</div>
  [% ELSIF whole.message %]
    <div class="alert alert-warning">[% whole.message | html %]</div>
  [% ELSE %]
    <div class="alert alert-warning">Unhandled error</div>
  [% END %]
[% END %]

[% IF whole.stage == "commit" %]
  <p>We have now created your request.</p>

[% ELSIF whole.stage == "search_form" %]
  <h2>Create an ILL request</h2>
  <form method="post" action="/cgi-bin/koha/opac-illrequests.pl">
    [% INCLUDE 'csrf-token.inc' %]
    <input type="hidden" name="op"      value="cud-create"/>
    <input type="hidden" name="method"  value="create"/>
    <input type="hidden" name="stage"   value="search_form"/>
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
          <label class="required" for="branchcode">Destination library:</label>
          <select class="required" required="required" id="branchcode" name="branchcode">
            <option value=""></option>
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
      <a class="cancel" href="/cgi-bin/koha/opac-illrequests.pl">Cancel</a>
    </fieldset>
  </form>

[% ELSIF whole.stage == "search_results" %]

  [% IF whole.value.results && whole.value.results.size %]
    <h2>Select an item to request</h2>

    <fieldset class="rows">
      <ol>
        <li>
          <label class="required" for="service_type">Service type:</label>
          <select class="required" required="required" id="service_type">
            <option value="Loan">Loan</option>
            <option value="Copy">Copy</option>
            <option value="CopyOrLoan" selected="selected">Copy or loan</option>
          </select>
          <span class="required">Required</span>
        </li>
      </ol>
    </fieldset>

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
            [% IF result.api_items && result.api_items.size %]
              <table class="w-100">
                [% FOREACH item IN result.api_items %]
                  <tr>
                    <td class="w-100">
                      <strong>[% item.libraryname | html %]</strong>
                      [% IF item.public_notes %]
                        ([% item.public_notes | html %])
                      [% END %]
                    </td>
                    <td>
                      [% PROCESS request_form result = result item = item label = 'Request this item' %]
                    </td>
                  </tr>
                [% END %]
              </table>
            [% ELSE %]
              [% PROCESS request_form result = result item = '' label = 'Request from this agency' %]
            [% END %]
          </td>
        </tr>
        [% END %]
      </tbody>
    </table>

    <p><a class="cancel" href="/cgi-bin/koha/opac-illrequests.pl">Cancel</a></p>
  [% ELSE %]
    <p>No results found. <a href="/cgi-bin/koha/opac-illrequests.pl">Back to your requests.</a></p>
  [% END %]

[% ELSE %]
  <p>Unknown stage. This should not have happened.</p>
[% END %]

[% BLOCK request_form %]
  <form class="request-item" method="post" action="/cgi-bin/koha/opac-illrequests.pl">
    [% INCLUDE 'csrf-token.inc' %]
    <input type="hidden" name="op"                 value="cud-create"/>
    <input type="hidden" name="method"             value="create"/>
    <input type="hidden" name="stage"              value="search_results"/>
    <input type="hidden" name="backend"            value="[% whole.other.backend | html %]"/>
    <input type="hidden" name="branchcode"         value="[% whole.branchcode | html %]"/>
    <input type="hidden" name="service_type"       value="CopyOrLoan"/>
    <input type="hidden" name="title"              value="[% result.title | html %]"/>
    <input type="hidden" name="author"             value="[% result.author | html %]"/>
    <input type="hidden" name="isbn"               value="[% result.isbn | html %]"/>
    <input type="hidden" name="issn"               value="[% result.issn | html %]"/>
    <input type="hidden" name="agency_index"       value="[% result.agency_index | html %]"/>
    <input type="hidden" name="supplier_biblio_id" value="[% result.biblio_id | html %]"/>
    [% IF item %]
      <input type="hidden" name="supplier_item_id"           value="[% item.item_id | html %]"/>
      <input type="hidden" name="supplier_item_barcode"      value="[% item.external_id | html %]"/>
      <input type="hidden" name="supplier_item_callnumber"   value="[% item.callnumber | html %]"/>
      <input type="hidden" name="supplier_item_library"      value="[% item.libraryname | html %]"/>
      <input type="hidden" name="supplier_item_public_notes" value="[% item.public_notes | html %]"/>
    [% END %]
    <button type="submit" class="btn btn-sm btn-primary">[% label | html %]</button>
  </form>
[% END %]

[% BLOCK backend_jsinclude %]
<script>
document.addEventListener('DOMContentLoaded', function () {
    function setServiceType() {
        $('#iso18626-results-table form.request-item input[name="service_type"]').val($('#service_type').val());
    }
    $('#service_type').on('change', setServiceType);
    setServiceType();
});
</script>
[% END %]
