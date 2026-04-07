[% cwd = whole.cwd %]

<h2>Edit request</h2>
<form method="POST" action="[% here %]" id="edit_form">
  [% INCLUDE 'csrf-token.inc' %]
  <fieldset class="rows">
    <legend>Edit metadata</legend>
    <input name="illrequest_id" value="[% whole.value.other.illrequest_id %]" type="hidden" />
    <input name="stage" id="stage" value="form" type="hidden"/>
    <input name="op" id="op" value="cud-edititem" type="hidden"/>
    <input name="backend" id="backend" value="ReprintsDesk" type="hidden"/>
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
      <li id="reprints_desk_field_[% key %]">
        <label class="reprints_desk_label" id="[% key %]_label" for="[% key %]">[% field.label | html %]</label>
        <input type="text" name="[% key %]" id="[% key %]" value="[% whole.value.other.$key %]" />
        [% IF field.help %]
        ([% field.help %])
        [% END %]
      </li>
      [% END %]
      [% END %]
    </ol>
  </fieldset>
  <fieldset class="action">
    <input id="update_submit" type="submit" value="Update"/>
    <a class="cancel" href="/cgi-bin/koha/ill/ill-requests.pl">Cancel</a>
  </fieldset>
</form>