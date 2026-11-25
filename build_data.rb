#!/usr/bin/env ruby
# encoding: utf-8
#
# Got Got Need — nightly data copy.
#
# Copies every club in England's top six tiers into data/ so the app loads instantly
# instead of asking Wikidata/Wikipedia live on every page view.
#
#   data/clubs.json        every club, grouped by division (from the league tables on Wikipedia)
#   data/teams/<Qid>.json  one file per club: facts, every player who played there (Wikidata),
#                          and the squad list for each season since 2010 (Wikipedia page history)
#
# Usage:
#   ruby build_data.rb                 # nightly update: refreshes club lists, player histories and
#                                      # current squads; past seasons already copied are kept
#   ruby build_data.rb --full          # re-copy every season from scratch
#   ruby build_data.rb --only Q19612   # just these clubs (comma-separated Wikidata ids)
#
# Set CONTACT=you@example.com (or a URL) so Wikimedia knows who to contact about the traffic,
# as their API rules ask: https://foundation.wikimedia.org/wiki/Policy:User-Agent_policy
#
# Data licences: Wikidata is CC0. Wikipedia squad lists are CC BY-SA (the app credits them).
# Photos stay on Wikimedia Commons; the app links them and credits the photographer.

require 'net/http'
require 'json'
require 'uri'
require 'fileutils'
require 'time'

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

UA = "GotGotNeed-databuild/0.1 (#{ENV['CONTACT'] || 'prototype, no contact set'}) Ruby/#{RUBY_VERSION}"
WD = 'https://www.wikidata.org/w/api.php'
WP = 'https://en.wikipedia.org/w/api.php'
SPARQL = 'https://query.wikidata.org/sparql'
OUT = File.join(__dir__, 'data')
TEAMS = File.join(OUT, 'teams')
NOW = Time.now.utc
CUR = NOW.month >= 7 ? NOW.year : NOW.year - 1   # football season starts in July
WIKI_FROM = 2010                                 # first season copied from Wikipedia page history
PARSER = 2                                       # bump when squad parsing improves: re-checks empty seasons
GAP = 0.35                                       # seconds between requests: be polite

FULL = ARGV.include?('--full')
ONLY = (i = ARGV.index('--only')) ? ARGV[i + 1].to_s.split(',') : nil

def season_label(y)
  "#{y}–#{(y + 1).to_s[-2..-1]}"
end

# ---------- HTTP with polite pacing and retries ----------
$last = Time.at(0)
$requests = 0
def get(url, params, accept = nil)
  uri = URI(url)
  uri.query = URI.encode_www_form(params.merge(format: 'json'))
  tries = 0
  loop do
    wait = GAP - (Time.now - $last)
    sleep wait if wait > 0
    $last = Time.now
    $requests += 1
    begin
      req = Net::HTTP::Get.new(uri)
      req['User-Agent'] = UA
      req['Accept'] = accept if accept
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 120) { |h| h.request(req) }
      return JSON.parse(res.body) if res.code == '200'
      err = "HTTP #{res.code}"
      delay = (res['retry-after'] || 0).to_i
    rescue StandardError => e
      err = e.class.name
      delay = 0
    end
    tries += 1
    raise "#{err} after #{tries} tries: #{url}" if tries > 6
    delay = [delay, 5 * tries].max
    warn "    #{err}, retrying in #{delay}s"
    sleep delay
  end
end

def follow(q, t)
  hop = {}
  ((q['normalized'] || []) + (q['redirects'] || [])).each { |x| hop[x['from']] = x['to'] }
  u = t
  3.times { u = hop[u] if hop[u] }
  u
end

def claims(e, p)
  (e.dig('claims', p) || []).select { |c| c['rank'] != 'deprecated' && c.dig('mainsnak', 'datavalue') }
end

def val(c)
  c['mainsnak']['datavalue']['value']
end

def fmt_date(t)
  y, m, d = t['time'][1, 10].split('-').map(&:to_i)
  t['precision'].to_i >= 11 ? Time.utc(y, m, d).strftime('%-d %B %Y') : y.to_s
end

# Wikipedia article titles -> Wikidata ids (follows redirects)
def qids(titles)
  map = {}
  titles.compact.uniq.each_slice(50) do |sl|
    q = get(WP, action: 'query', titles: sl.join('|'), redirects: 1, prop: 'pageprops', ppprop: 'wikibase_item', formatversion: 2)['query']
    by = {}
    (q['pages'] || []).each { |p| by[p['title']] = p.dig('pageprops', 'wikibase_item') if p.dig('pageprops', 'wikibase_item') }
    sl.each { |t| (id = by[follow(q, t)]) && (map[t] = id) }
  end
  map
end

def labels(ids)
  out = {}
  ids.compact.uniq.each_slice(50) do |sl|
    get(WD, action: 'wbgetentities', ids: sl.join('|'), props: 'labels', languages: 'en')['entities'].each { |id, e| out[id] = e.dig('labels', 'en', 'value') }
  end
  out
end

def photos(ids)
  out = {}
  ids.compact.uniq.each_slice(50) do |sl|
    get(WD, action: 'wbgetentities', ids: sl.join('|'), props: 'claims')['entities'].each do |id, e|
      c = claims(e, 'P18').first
      out[id] = 'https://commons.wikimedia.org/wiki/Special:FilePath/' + URI.encode_www_form_component(val(c)).gsub('+', '%20') if c
    end
  end
  out
end

# ---------- club lists ----------
LEAGUES = [
  ['Premier League', 'Tier 1', ->(s) { "#{s} Premier League" }],
  ['Championship', 'Tier 2', ->(s) { "#{s} EFL Championship" }],
  ['League One', 'Tier 3', ->(s) { "#{s} EFL League One" }],
  ['League Two', 'Tier 4', ->(s) { "#{s} EFL League Two" }],
  ['National League', 'Tier 5', ->(s) { "Template:#{s} National League table" }],
  ['National League North', 'Tier 6', ->(s) { "Template:#{s} National League North table" }],
  ['National League South', 'Tier 6', ->(s) { "Template:#{s} National League South table" }]
].freeze
NAME_RE = /name_([^\s=|]+)\s*=\s*(?:\{\{\s*nowrap\s*\|\s*)?\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/i

def page_texts(titles)
  q = get(WP, action: 'query', prop: 'revisions', rvprop: 'content', rvslots: 'main', titles: titles.join('|'), redirects: 1, formatversion: 2)['query']
  by = {}
  (q['pages'] || []).each { |p| by[p['title']] = p.dig('revisions', 0, 'slots', 'main', 'content') || '' }
  ->(t) { by[follow(q, t)] || '' }
end

def parse_clubs(txt)
  seen = {}
  out = []
  txt.scan(NAME_RE) do |k, t, n|
    next if seen[k]
    seen[k] = true
    out << { 'title' => t.strip, 'name' => (n || t).sub(/\s*F\.C\.\z/, '').strip }
  end
  out
end

def build_clubs
  text = page_texts(LEAGUES.map { |l| l[2].call(season_label(CUR)) })
  lists = LEAGUES.map { |l| parse_clubs(text.call(l[2].call(season_label(CUR)))) }
  missing = lists.each_index.select { |i| lists[i].empty? }
  unless missing.empty?   # this season's table not written yet: use last season's
    text = page_texts(missing.map { |i| LEAGUES[i][2].call(season_label(CUR - 1)) })
    missing.each { |i| lists[i] = parse_clubs(text.call(LEAGUES[i][2].call(season_label(CUR - 1)))) }
  end
  ids = qids(lists.flatten.map { |c| c['title'] })
  leagues = LEAGUES.each_with_index.map do |(name, tier, _), i|
    clubs = lists[i].map { |c| c.merge('id' => ids[c['title']]) }.select { |c| c['id'] }.sort_by { |c| c['name'] }
    { 'name' => name, 'tier' => tier, 'clubs' => clubs }
  end
  File.write(File.join(OUT, 'clubs.json'), JSON.generate('season' => CUR, 'built' => NOW.iso8601, 'leagues' => leagues))
  leagues
end

# ---------- squad lists from Wikipedia ({{Fs player}} templates) ----------
def grab_template(ch, i)
  d = 0
  j = i
  while j < ch.length - 1
    a = ch[j]
    b = ch[j + 1]
    if a == '{' && b == '{'
      d += 1
      j += 1
    elsif a == '}' && b == '}'
      d -= 1
      j += 1
      return ch[i..j].join if d.zero?
    end
    j += 1
  end
  nil
end

def split_params(t)
  ch = t.chars
  out = []
  d = 0
  cur = +''
  j = 2
  while j < ch.length - 2
    c = ch[j]
    n = ch[j + 1]
    if (c == '{' && n == '{') || (c == '[' && n == '[')
      d += 1; cur << c << n; j += 2; next
    end
    if (c == '}' && n == '}') || (c == ']' && n == ']')
      d -= 1; cur << c << n; j += 2; next
    end
    if c == '|' && d.zero?
      out << cur; cur = +''; j += 1; next
    end
    cur << c
    j += 1
  end
  out << cur
  params = {}
  out[1..-1].each do |x|
    k = x.index('=')
    params[x[0...k].strip.downcase] = x[(k + 1)..-1].strip if k && k > 0
  end
  params
end

def plain(s)
  (s || '').gsub(/\{\{[^{}]*\}\}/, '').gsub(/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/, '\1').gsub(/<[^>]+>|'''?/, '').gsub(/\s+/, ' ').strip
end

def parse_name(v)
  if (m = v.match(/\{\{\s*sort\s*name\s*\|([^|}]+)\|([^|}]+)(?:\|([^|}]+))?/i))
    return { 'name' => "#{m[1]} #{m[2]}".strip, 'title' => (m[3] || "#{m[1]} #{m[2]}").strip }
  end
  if (m = v.match(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/))
    return { 'name' => (m[2] || m[1]).strip, 'title' => m[1].strip }
  end
  { 'name' => plain(v), 'title' => nil }
end

POSMAP = { 'GK' => 'Goalkeepers', 'DF' => 'Defenders', 'MF' => 'Midfielders', 'FW' => 'Forwards' }.freeze

# the club article's squad list as it stood on 1 November of season y (latest version for this season)
def squad_snapshot(wiki, y)
  params = { action: 'query', prop: 'revisions', rvprop: 'content|timestamp|ids', rvslots: 'main', titles: wiki, redirects: 1, formatversion: 2, rvlimit: 1 }
  params.merge!(rvstart: "#{y}-11-01T00:00:00Z", rvdir: 'older') if y != CUR
  rev = get(WP, params).dig('query', 'pages', 0, 'revisions', 0)
  return nil unless rev
  txt = rev.dig('slots', 'main', 'content') || ''
  a = txt.index(/\{\{\s*(?:fs|football squad)\s*start/i)
  return nil unless a
  rest = txt[a..-1]
  b = rest.index(/\{\{\s*(?:fs|football squad)\s*end/i)
  block = b ? rest[0...b] : rest[0, 30_000]
  ch = block.chars
  starts = []
  block.scan(/\{\{\s*(?:fs\s*player|football squad player)\s*\|/i) { starts << Regexp.last_match.begin(0) }
  players = starts.map do |i|
    t = grab_template(ch, i)
    next unless t
    p = split_params(t)
    next if p['name'].to_s.empty?
    pos = p['pos'].to_s.upcase
    parse_name(p['name']).merge('no' => plain(p['no']), 'pos' => pos, 'other' => plain(p['other']), 'group' => POSMAP[pos] || 'Other')
  end.compact
  return nil if players.size < 8
  { 'players' => players, 'asOf' => rev['timestamp'][0, 10], 'revid' => rev['revid'] }
end

SQUAD_QUERY = <<~Q
  SELECT ?p ?pLabel ?start ?sp ?end ?ep ?apps ?goals ?img ?posLabel WHERE {
    ?p p:P54 ?st. ?st ps:P54 wd:%s.
    OPTIONAL{?st pqv:P580 [wikibase:timeValue ?start; wikibase:timePrecision ?sp]}
    OPTIONAL{?st pqv:P582 [wikibase:timeValue ?end; wikibase:timePrecision ?ep]}
    OPTIONAL{?st pq:P1350 ?apps} OPTIONAL{?st pq:P1351 ?goals}
    OPTIONAL{?p wdt:P18 ?img} OPTIONAL{?p wdt:P413 ?pos}
    SERVICE wikibase:label{bd:serviceParam wikibase:language "en,es,fr,de,it".}}
Q

def build_team(id)
  file = File.join(TEAMS, "#{id}.json")
  old = File.exist?(file) && !FULL ? (JSON.parse(File.read(file)) rescue {}) : {}

  e = get(WD, action: 'wbgetentities', ids: id, props: 'labels|claims|sitelinks', languages: 'en', sitefilter: 'enwiki')['entities'][id]
  ref = ->(p) { claims(e, p).map { |c| val(c)['id'] }.compact }
  l = labels(ref.call('P17') + ref.call('P115') + ref.call('P118'))
  founded = claims(e, 'P571').first
  facts = [['Founded', founded && fmt_date(val(founded))], ['Ground', l[ref.call('P115').last]],
           ['League', l[ref.call('P118').last]], ['Country', l[ref.call('P17').first]]].select { |_, v| v && !v.empty? }
  wiki = e.dig('sitelinks', 'enwiki', 'title')

  # every player who has played for the club, with join/leave dates (Wikidata)
  b = get(SPARQL, { query: format(SQUAD_QUERY, id) }, 'application/sparql-results+json')['results']['bindings']
  v = ->(r, k) { r[k] && r[k]['value'] }
  rows = b.map { |r| [v.call(r, 'p').split('/').last, v.call(r, 'pLabel'), v.call(r, 'start'), v.call(r, 'sp'), v.call(r, 'end'), v.call(r, 'ep'),
                      v.call(r, 'apps'), v.call(r, 'goals'), v.call(r, 'img'), v.call(r, 'posLabel')] }

  # season squad lists (past seasons never change, so only fetch what's missing, plus the current one)
  ws = old['ws'] || {}
  fresh = []
  if wiki
    (WIKI_FROM..CUR).each do |y|
      # keep seasons already copied; re-check empty ones if the parser has improved since
      next if y != CUR && ws.key?(y.to_s) && (ws[y.to_s] || old['parser'] == PARSER)
      ws[y.to_s] = squad_snapshot(wiki, y)
      fresh << ws[y.to_s] if ws[y.to_s]
    end
  end
  # link newly copied squad players to their profiles and photos
  titles = fresh.flat_map { |s| s['players'].map { |p| p['title'] } }.compact.uniq
  unless titles.empty?
    ids = qids(titles)
    img = photos(ids.values)
    fresh.each { |s| s['players'].each { |p| p['id'] = ids[p['title']]; p['img'] = p['id'] && img[p['id']] } }
  end

  data = { 'id' => id, 'name' => e.dig('labels', 'en', 'value') || id, 'wiki' => wiki, 'facts' => facts,
           'rows' => rows, 'ws' => ws, 'wikiFrom' => WIKI_FROM, 'parser' => PARSER, 'built' => NOW.iso8601 }
  File.write(file, JSON.generate(data))
  [rows.map(&:first).uniq.size, ws[CUR.to_s] ? ws[CUR.to_s]['players'].size : 0]
end

# ---------- main ----------
FileUtils.mkdir_p(TEAMS)
t0 = Time.now
puts "Got Got Need data build — season #{season_label(CUR)}#{FULL ? ' (full rebuild)' : ''}"
leagues = build_clubs
clubs = leagues.flat_map { |lg| lg['clubs'].map { |c| c.merge('league' => lg['name']) } }
clubs = clubs.select { |c| ONLY.include?(c['id']) } + (ONLY - clubs.map { |c| c['id'] }).map { |q| { 'id' => q, 'name' => q, 'league' => '-' } } if ONLY
puts "#{clubs.size} clubs to copy"
failed = []
clubs.each_with_index do |c, i|
  print format('[%3d/%d] %-28s %-22s ', i + 1, clubs.size, c['name'][0, 28], c['league'])
  begin
    all_time, current = build_team(c['id'])
    puts "#{all_time} all-time, #{current} in current squad"
  rescue StandardError => e
    failed << c['name']
    puts "FAILED: #{e.message[0, 120]}"
  end
end
mins = ((Time.now - t0) / 60).round(1)
puts "Done in #{mins} min, #{$requests} requests. #{failed.empty? ? 'No failures.' : "Failed: #{failed.join(', ')} (they'll load live; rerun to retry)"}"
exit(failed.empty? ? 0 : 1)
