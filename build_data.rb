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
#   data/players/<Qid>.json one file per player at those clubs: profile, career, honours, bio, photo credit
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

# ---------- player profiles ----------
# One file per player who has played for any copied club: data/players/<Qid>.json, in the shape
# the app's profile page reads. Done 50 players per request, so ~36,000 players is ~2,500 requests.
require 'zlib'
PLAYERS = File.join(OUT, 'players')
COMMONS = 'https://commons.wikimedia.org/w/api.php'
NATIONAL_RE = /national|under-\d|\bU-?\d\d\b|olympic/i
$labels = {}

def qual(c, p)
  c.dig('qualifiers', p, 0, 'datavalue', 'value')
end

def year_of(t)
  t && t['time'] ? t['time'][0, 5].to_i : nil
end

def fetch_labels(ids)
  need = ids.compact.uniq.reject { |i| $labels.key?(i) }
  need.each_slice(50) do |sl|
    get(WD, action: 'wbgetentities', ids: sl.join('|'), props: 'labels', languages: 'en|en-gb|es|fr|de|it')['entities'].each do |id, e|
      ls = e['labels'] || {}
      $labels[id] = (ls['en'] || ls.values.first || {})['value'] || ''
    end
  end
end

# first paragraph of each article's intro, like the app's live bio
def fetch_bios(titles)
  out = {}
  titles.compact.uniq.each_slice(20) do |sl|
    q = get(WP, action: 'query', prop: 'extracts', exintro: 1, explaintext: 1, exlimit: 20, titles: sl.join('|'), redirects: 1, formatversion: 2)['query']
    by = {}
    (q['pages'] || []).each { |p| by[p['title']] = p['extract'].to_s.split("\n").map(&:strip).reject(&:empty?).first.to_s[0, 1500] }
    sl.each { |t| out[t] = by[follow(q, t)] || '' }
  end
  out
end

# photographer and licence for each Commons photo
def fetch_credits(files)
  out = {}
  files.compact.uniq.each_slice(50) do |sl|
    titles = sl.map { |f| "File:#{f}" }
    q = get(COMMONS, action: 'query', titles: titles.join('|'), prop: 'imageinfo', iiprop: 'extmetadata', iiextmetadatafilter: 'Artist|LicenseShortName', formatversion: 2)['query']
    by = {}
    (q['pages'] || []).each do |p|
      md = p.dig('imageinfo', 0, 'extmetadata') || {}
      by[p['title']] = { 'artist' => md.dig('Artist', 'value').to_s.gsub(/<[^>]+>/, '').strip, 'license' => md.dig('LicenseShortName', 'value').to_s }
    end
    sl.each { |f| (c = by[follow(q, "File:#{f}")]) && (out[f] = c) }
  end
  out
end

def player_model(id, e, bios, credits)
  ref = ->(p) { claims(e, p).map { |c| val(c)['id'] }.compact }
  lab = ->(i) { i ? $labels[i].to_s : '' }
  teams = claims(e, 'P54').map do |c|
    tid = val(c)['id']
    apps = qual(c, 'P1350')
    goals = qual(c, 'P1351')
    { 'id' => tid, 'label' => lab.call(tid), 'national' => !!(lab.call(tid) =~ NATIONAL_RE),
      's' => year_of(qual(c, 'P580')), 'e' => year_of(qual(c, 'P582')),
      'apps' => apps && apps['amount'].to_i, 'goals' => goals && goals['amount'].to_i,
      'loan' => (c.dig('qualifiers', 'P1642') || []).any? { |x| x.dig('datavalue', 'value', 'id') == 'Q2914547' } }
  end
  awards = claims(e, 'P166').map { |c| { 'label' => lab.call(val(c)['id']), 'y' => year_of(qual(c, 'P585')) } }
  born = claims(e, 'P569').first
  h = claims(e, 'P2048').first
  height = if h
             v = val(h)
             a = v['amount'].to_f
             v['unit'].to_s.end_with?('Q11573') ? format('%.2f m', a) : "#{a == a.to_i ? a.to_i : a} cm"
           else '' end
  facts = [['Born', born ? fmt_date(val(born)) : ''], ['Birthplace', lab.call(ref.call('P19').first)],
           ['Nation', lab.call(ref.call('P1532').first || ref.call('P27').first)],
           ['Position', ref.call('P413').map { |i| lab.call(i) }.reject(&:empty?).first(2).join(', ')],
           ['Height', height], ['Sport', lab.call(ref.call('P641').first)]].reject { |_, v| v.to_s.empty? }
  wiki = e.dig('sitelinks', 'enwiki', 'title')
  img = claims(e, 'P18').first
  img = img && val(img)
  num = claims(e, 'P1618').first
  { 'id' => id, 'name' => e.dig('labels', 'en', 'value') || (e['labels'] || {}).values.first&.dig('value') || id,
    'desc' => e.dig('descriptions', 'en', 'value').to_s, 'wiki' => wiki, 'bio' => wiki ? bios[wiki].to_s : '',
    'img' => img, 'credit' => img && credits[img], 'num' => num && val(num).to_s,
    'facts' => facts, 'teams' => teams, 'awards' => awards, 'built' => NOW.iso8601 }
end

def build_players(team_ids)
  FileUtils.mkdir_p(PLAYERS)
  all = {}
  current = {}
  team_ids.each do |tid|
    f = File.join(TEAMS, "#{tid}.json")
    next unless File.exist?(f)
    t = JSON.parse(File.read(f))
    t['rows'].each { |r| all[r[0]] = true }
    (t['ws'] || {}).each do |y, s|
      next unless s
      s['players'].each do |p|
        next unless p['id']
        all[p['id']] = true
        current[p['id']] = true if y.to_i == CUR
      end
    end
  end
  ids = all.keys.select { |i| i =~ /\AQ\d+\z/ }
  # refresh: anyone not copied yet, current squads (stats change), and a rotating 1/30th of everyone else
  slot = NOW.yday % 30
  todo = ids.select { |i| FULL || current[i] || Zlib.crc32(i) % 30 == slot || !File.exist?(File.join(PLAYERS, "#{i}.json")) }
  puts "Players: #{ids.size} in total, copying #{todo.size} (#{current.size} in current squads)"
  done = 0
  failed = 0
  todo.each_slice(50).with_index do |chunk, n|
    begin
      ents = get(WD, action: 'wbgetentities', ids: chunk.join('|'), props: 'labels|descriptions|claims|sitelinks', languages: 'en', sitefilter: 'enwiki')['entities']
      ents = ents.reject { |_, e| e.key?('missing') }
      refs = ents.values.flat_map do |e|
        %w[P19 P27 P1532 P413 P641 P54 P166].flat_map { |p| claims(e, p).map { |c| val(c)['id'] } }
      end
      fetch_labels(refs)
      bios = fetch_bios(ents.values.map { |e| e.dig('sitelinks', 'enwiki', 'title') })
      credits = fetch_credits(ents.values.map { |e| (c = claims(e, 'P18').first) && val(c) })
      ents.each do |id, e|
        File.write(File.join(PLAYERS, "#{id}.json"), JSON.generate(player_model(id, e, bios, credits)))
        done += 1
      end
    rescue StandardError => e
      failed += chunk.size
      warn "    players batch #{n + 1} failed: #{e.message[0, 120]}"
    end
    puts "  players: #{done} copied" if (n + 1) % 40 == 0
  end
  puts "Players: #{done} copied#{failed > 0 ? ", #{failed} failed (they load live; retried tomorrow)" : ''}"
  failed
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
failed << 'some players' if build_players(clubs.map { |c| c['id'] }) > 0
mins = ((Time.now - t0) / 60).round(1)
puts "Done in #{mins} min, #{$requests} requests. #{failed.empty? ? 'No failures.' : "Failed: #{failed.join(', ')} (they'll load live; rerun to retry)"}"
exit(failed.empty? ? 0 : 1)
