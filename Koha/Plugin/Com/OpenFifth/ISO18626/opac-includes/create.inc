[% USE Koha %]

[% cwd = whole.cwd %]

[% IF whole.error %]
  [% IF whole.status == 'missing_fields' %]
    <p><em>Please Note:</em> Some mandatory fields are missing.</p>
  [% ELSIF whole.status == 'missing_branch' %]
    <p><em>Please Note:</em> Branch is a mandatory field.</p>
  [% ELSIF whole.status == 'invalid_borrower' %]
    <p><em>Please Note:</em> The borrower details you entered are invalid.</p>
  [% ELSIF whole.status == 'invalid_branch' %]
    <p><em>Please Note:</em> The branch you chose is invalid.</p>
  [% ELSIF whole.status == 'invalid_metadata' %]
    <p><em>Please Note:</em> You did not supply the correct metadata for the selected material type.</p>
  [% ELSIF whole.status == 'api' %]
    <p><em>Please Note:</em> there was an error whilst communicating with the remote service.</p>
  [% ELSIF whole.message %]
    <p><em>[% whole.message %]</em></p>
  [% ELSE %]
    <p><em>Unhandled error</em></p>
  [% END %]
[% END %]
    <p id="reprints_desk_warning"><em>Please Note</em>: Either DOI or PubMed ID must be completed.</p>

<div role="alert" class="alert alert-warning" id="request-notpossible" style="display: none">
  Item cannot be requested
  <div id="localholdings" style="display:none"></div>
</div>

[% IF whole.stage == "commit" %]
<p>We have now created your request.</p>

[% ELSIF whole.stage == "init" %]
<form method="POST" id="create_form">
  <fieldset class="rows">
    <legend>Place an interlibrary loan request</legend>
    <input name="stage" id="stage" value="validate" type="hidden"/>
    <input name="method" id="method" value="create" type="hidden"/>
    <input name="backend" id="backend" value="[% whole.value.other.backend %]" type="hidden"/>
    <ol>
      <li id="reprints_desk_field_title">
        <label class="reprints_desk_label" id="title_label" for="title">[% whole.field_map.0.label | html %]</label>
        <textarea type="text" name="title" id="title"/>[% whole.value.other.title %]</textarea>
      </li>
      <li id="reprints_desk_field_atitle">
        <label class="reprints_desk_label" id="atitle_label" for="atitle">[% whole.field_map.1.label | html %]</label>
        <textarea type="text" name="atitle" id="atitle"/>[% whole.value.other.atitle %]</textarea>
      </li>
      [% FOREACH field IN whole.field_map %]
      [% key = field.key %]
      [% IF !field.exclude %]
      [% IF field.hide %]
      <div style="display:none">
      [% END %]
      <li id="reprints_desk_field_[% key %]">
        <label id="[% key %]_label" for="[% key %]"></label>
        <input type="text" name="[% key %]" id="[% key %]" value="[% whole.value.other.$key %]" />
        [% IF field.help %]
        ([% field.help %])
        [% END %]
      </li>
      [% IF field.hide %]
      </div>
      [% END %]
      [% END %]
      [% END %]
    </ol>
  </fieldset>
  <fieldset class="rows">
    <legend>Patron options</legend>
    <ol>
      <li>
        <label class="required" for="branchcode">Destination library:</label>
        <select id="branchcode" name="branchcode">
          <option value="" />
          [% FOREACH branch IN branches %]
          [% IF ( whole.value.other.branchcode == branch.branchcode ) %]
          <option value="[% branch.branchcode %]" selected="selected">[% branch.branchname %]</option>
          [% ELSE %]
          <option value="[% branch.branchcode %]">[% branch.branchname %]</option>
          [% END %]
          [% END %]
        </select>
      </li>
    </ol>
  </fieldset>
  <fieldset class="action">
    <input id="reprints_desk_submit" type="submit" value="Make request"/>
    <a class="cancel" href="/cgi-bin/koha/opac-illrequests.pl">Cancel</a>
  </fieldset>
</form>

[% BLOCK backend_jsinclude %]
<script>
  document.addEventListener('DOMContentLoaded', function(){
    // Fields that are not in groups, but cannot be empty
    var notEmpty = [ ];

    var listenerSelectors = '';

    var fieldmap = [% whole.field_map_json %];

    [% INCLUDE "${cwd}/opac-includes/create.js" %]

    addLabels();
  });
</script>
[% END %]

[% END %]
