#!/usr/bin/perl
# Crypto Watchdesk - builder. Runs the same locally (Git Bash perl) and in GitHub Actions.
#   perl build.pl [--limit N] [--top N] [--previous previous.json] [--out dist]
# 1. Universe: the most-traded OKX USDT perpetual swaps (24h USD volume), stablecoins and non-crypto perps removed.
# 2. Per coin: 300 daily candles + funding history (OKX), open interest (OKX), funding now (Hyperliquid).
# 3. Momentum: swing z-score vs own 200-day return distribution, 7/30/90d vol-adjusted momentum rank,
#    moving-average trend, 20/55-day channel breakouts, volume surge, funding crowding.
# 4. Funding carry: daily funding for BTC/ETH/SOL on OKX, Hyperliquid, Kraken, Deribit vs the 3-month T-bill.
#    History is carried forward from the previous data.json, so a venue that fails on one run keeps its past days.
# Public data only. Not investment advice.
use strict; use warnings; use JSON::PP; use File::Path qw(make_path); use POSIX qw(strftime floor);
use Time::HiRes qw(sleep);

my %o = (limit => 0, top => 75, previous => '', out => 'dist');
while (@ARGV) { my $a = shift; if ($a =~ /^--(limit|top|previous|out)$/) { $o{$1} = shift } }
my $UA  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36';
my $NOW = time; my @log;
my $TODAY = strftime('%Y-%m-%d', gmtime($NOW));
sub note { my $m = shift; print "$m\n"; push @log, $m; }
sub curl { my ($url, @extra) = @_; my $q = join ' ', map { "'$_'" } @extra; my $b = `curl -sS -L --max-time 30 -A '$UA' $q '$url' 2>/dev/null`; return $b // ''; }
sub js   { my $b = shift; return undef unless defined $b && length $b; my $r = eval { JSON::PP->new->utf8(1)->decode($b) }; return $r; }
sub slurp { my $f = shift; open my $h, '<:raw', $f or return ''; local $/; my $t = <$h>; close $h; $t }
sub rd   { my ($v, $d) = @_; return undef unless defined $v; return sprintf("%.${d}f", $v) + 0 }
sub sig  { my ($v, $n) = @_; return undef unless defined $v; return 0 if $v == 0; return sprintf("%.${n}g", $v) + 0 }
sub mean { return undef unless @_; my $s = 0; $s += $_ for @_; $s / @_ }
sub sd   { return undef if @_ < 2; my $m = mean(@_); my $s = 0; $s += ($_ - $m) ** 2 for @_; sqrt($s / (@_ - 1)) }
sub maxv { my $m; for (@_) { $m = $_ if !defined $m || $_ > $m } $m }
sub minv { my $m; for (@_) { $m = $_ if !defined $m || $_ < $m } $m }
sub okx  { my $p = shift; for my $t (0..2) { my $r = js(curl("https://www.okx.com$p")); return $r->{data} if $r && defined $r->{code} && $r->{code} eq '0' && ref $r->{data} eq 'ARRAY'; sleep(1 + 2 * $t) } return undef }
sub hl   { my $body = shift; for my $t (0..2) { my $r = js(curl('https://api.hyperliquid.xyz/info', '-H', 'Content-Type: application/json', '-d', $body)); return $r if $r; sleep(1 + 2 * $t) } return undef }

my $prev = ($o{previous} && -s $o{previous}) ? js(slurp($o{previous})) : undef;
note("previous data: ".($prev ? "found, generated ".($prev->{gen} // '?') : 'none'));

# ---------- 1. universe ----------
my %SKIP = map { $_ => 1 } qw(USDC USDT DAI FDUSD TUSD USDE USD1 PYUSD USDS EURT XAUT PAXG XAU XAG);
my $tick = okx('/api/v5/market/tickers?instType=SWAP') or die "OKX tickers unavailable\n";
my @uni;
# OKX also lists stock, pre-IPO and commodity perps; instCategory "1" = crypto. Fail closed if the list is missing.
my %crypto; { my $ins = okx('/api/v5/public/instruments?instType=SWAP') or die "OKX instruments unavailable\n";
  for (@$ins) { $crypto{$_->{instId}} = 1 if ($_->{instCategory} // '') eq '1' && ($_->{ruleType} // 'normal') eq 'normal' && ($_->{state} // 'live') eq 'live' } }
for my $t (@$tick) {
  next unless $t->{instId} =~ /^([A-Z0-9]+)-USDT-SWAP$/; my $s = $1; next if $SKIP{$s} || !$crypto{$t->{instId}};
  my ($last, $open, $vc) = ($t->{last}, $t->{open24h}, $t->{volCcy24h}); next unless $last && $open && $vc;
  push @uni, { s => $s, id => $t->{instId}, px => $last + 0, open => $open + 0, vol24 => $vc * $last };
}
@uni = sort { $b->{vol24} <=> $a->{vol24} } @uni;
note("universe: ".scalar(@uni)." OKX USDT perps, keeping top $o{top} by 24h volume");
splice(@uni, $o{top}) if @uni > $o{top};
splice(@uni, $o{limit}) if $o{limit} && @uni > $o{limit};

# names and market caps (CoinGecko, optional; previous run as fallback)
my (%cg, %pname);
if ($prev) { $pname{$_->{s}} = $_ for @{$prev->{coins} // []} }
{ my $r = js(curl('https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&order=market_cap_desc&per_page=250&page=1'));
  my $r2 = (ref $r eq 'ARRAY') ? js(curl('https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&order=market_cap_desc&per_page=250&page=2')) : undef;
  for my $c ((ref $r eq 'ARRAY' ? @$r : ()), (ref $r2 eq 'ARRAY' ? @$r2 : ())) { my $k = uc($c->{symbol} // ''); next if !$k || $cg{$k}; $cg{$k} = { name => $c->{name}, mcap => $c->{market_cap}, px => $c->{current_price} } }
  note("coingecko names: ".scalar(keys %cg).(%cg ? '' : ' (unavailable, using previous run)')); }

# open interest (one call) and Hyperliquid funding (one call)
my %oi; { my $d = okx('/api/v5/public/open-interest?instType=SWAP'); if ($d) { $oi{$_->{instId}} = $_->{oiUsd} for @$d } note("okx open interest: ".scalar(keys %oi)); }
my %hlf; { my $r = hl('{"type":"metaAndAssetCtxs"}');
  if (ref $r eq 'ARRAY' && $r->[0]{universe}) { my $u = $r->[0]{universe}; for my $i (0..$#$u) { my $n = $u->[$i]{name}; next if $u->[$i]{isDelisted}; my $c = $r->[1][$i] or next; next unless defined $c->{funding};
      $hlf{$n} = { f => $c->{funding} * 24 * 365 * 100, oi => ($c->{openInterest} // 0) * ($c->{markPx} // 0) } } }
  note("hyperliquid perps: ".scalar(keys %hlf)); }

# ---------- 2. per-coin history ----------
my @coins;
for my $u (@uni) {
  my $cd = okx("/api/v5/market/candles?instId=$u->{id}&bar=1Dutc&limit=300");
  unless ($cd && @$cd >= 15) { note("skip $u->{s}: no candle history"); next }
  my @c = reverse @$cd;                                    # oldest first; last row is today's live candle
  my @cl = map { $_->[4] + 0 } @c; my @hi = map { $_->[2] + 0 } @c; my @lo = map { $_->[3] + 0 } @c; my @vq = map { ($_->[7] // 0) + 0 } @c;
  $cl[-1] = $u->{px}; my $n = @cl;
  my @lr = map { log($cl[$_] / $cl[$_ - 1]) } grep { $cl[$_] > 0 && $cl[$_ - 1] > 0 } 1 .. $n - 2;   # completed days only
  my @l200 = @lr > 200 ? @lr[-200 .. -1] : @lr;
  my $sg = @l200 >= 30 ? sd(@l200) : undef;
  my $ret = sub { my $k = shift; return undef if $n <= $k || !$cl[-1 - $k]; $cl[-1] / $cl[-1 - $k] - 1 };
  my %c = (s => $u->{s}, px => $u->{px}, vol24 => rd($u->{vol24}, 0), days => $n);
  my $r24 = $u->{px} / $u->{open} - 1; my ($r7, $r30, $r90) = ($ret->(7), $ret->(30), $ret->(90));
  # 1-hour change: close of the 5-minute candle that ended 55-60 minutes ago
  { my $m5 = okx("/api/v5/market/candles?instId=$u->{id}&bar=5m&limit=13"); if ($m5 && @$m5 >= 13 && $m5->[12][4] > 0) { $c{r1} = rd(($u->{px} / $m5->[12][4] - 1) * 100, 2) } }
  $c{r24} = rd($r24 * 100, 2); $c{r7} = rd($r7 * 100, 1) if defined $r7; $c{r30} = rd($r30 * 100, 1) if defined $r30; $c{r90} = rd($r90 * 100, 1) if defined $r90;
  if ($sg) { $c{z} = rd(log(1 + $r24) / $sg, 2); $c{dvol} = rd($sg * 100, 2);
    my ($num, $w) = (0, 0); for my $p ([7, $r7, .2], [30, $r30, .4], [90, $r90, .4]) { next unless defined $p->[1] && $p->[1] > -1; $num += $p->[2] * log(1 + $p->[1]) / ($sg * sqrt($p->[0])); $w += $p->[2] }
    $c{mom} = rd($num / $w, 2) if $w >= .6; }
  my @l30 = @lr > 30 ? @lr[-30 .. -1] : @lr; $c{rv30} = rd(sd(@l30) * sqrt(365) * 100, 0) if @l30 >= 20;
  my $ma = sub { my $k = shift; return undef if $n < $k; mean(@cl[-$k .. -1]) };
  my ($m20, $m50, $m200) = ($ma->(20), $ma->(50), $ma->(200));
  $c{d20} = rd(($u->{px} / $m20 - 1) * 100, 1) if $m20; $c{d50} = rd(($u->{px} / $m50 - 1) * 100, 1) if $m50; $c{d200} = rd(($u->{px} / $m200 - 1) * 100, 1) if $m200;
  $c{trend} = !($m20 && $m50) ? 'na' : ($u->{px} > $m20 && $m20 > $m50) ? 'up' : ($u->{px} < $m20 && $m20 < $m50) ? 'down' : 'mixed';
  my $chan = sub { my $k = shift; return () if $n < $k + 1; (maxv(@hi[-$k - 1 .. -2]), minv(@lo[-$k - 1 .. -2])) };
  my ($h20, $l20) = $chan->(20); my ($h55, $l55) = $chan->(55);
  $c{brk} = (defined $h55 && $u->{px} > $h55) ? 55 : (defined $h20 && $u->{px} > $h20) ? 20 : (defined $l55 && $u->{px} < $l55) ? -55 : (defined $l20 && $u->{px} < $l20) ? -20 : 0;
  my $k90 = $n < 90 ? $n : 90; my $h90 = maxv(@hi[-$k90 .. -1]); $c{dd90} = rd(($u->{px} / $h90 - 1) * 100, 1) if $h90;
  my @v30 = grep { $_ > 0 } ($n > 31 ? @vq[-31 .. -2] : @vq[0 .. $n - 2]); my $av = mean(@v30); $c{volx} = rd($u->{vol24} / $av, 2) if $av;
  $c{t0} = int($c[0][0] / 1000); $c{spark} = [map { sig($_, 5) } @cl];
  $c{oi} = rd($oi{$u->{id}}, 0) if $oi{$u->{id}};
  # funding (OKX history: ~100 most recent settlements)
  my $fh = okx("/api/v5/public/funding-rate-history?instId=$u->{id}&limit=100");
  if ($fh && @$fh >= 2) {
    my $ih = ($fh->[0]{fundingTime} - $fh->[1]{fundingTime}) / 3600000; $ih = 8 if $ih <= 0;
    my $rate = sub { my $x = shift; defined $x->{realizedRate} && length $x->{realizedRate} ? $x->{realizedRate} : $x->{fundingRate} };
    $c{f_now} = rd($rate->($fh->[0]) * 8760 / $ih * 100, 1); $c{f_int} = $ih + 0;
    my ($sum, $cut, $old) = (0, ($NOW - 7 * 86400) * 1000, $fh->[-1]{fundingTime});
    for (@$fh) { $sum += $rate->($_) if $_->{fundingTime} >= $cut }
    $c{f7} = rd($sum / 7 * 365 * 100, 1) if $old <= $cut + 86400000;
  }
  my $hk = $hlf{$u->{s}} ? $u->{s} : $hlf{"k$u->{s}"} ? "k$u->{s}" : undef;
  if ($hk) { $c{hl_now} = rd($hlf{$hk}{f}, 1); $c{hl_oi} = rd($hlf{$hk}{oi}, 0) }
  my $g = $cg{$u->{s}}; my $p = $pname{$u->{s}};
  if ($g && $g->{px} && abs($g->{px} / $u->{px} - 1) < .15) { $c{name} = $g->{name}; $c{mcap} = $g->{mcap} if $g->{mcap} }
  elsif ($p && $p->{name}) { $c{name} = $p->{name}; $c{mcap} = $p->{mcap} if $p->{mcap} }
  $c{name} //= $u->{s};
  push @coins, \%c; sleep(0.12);
}
die "no coin data\n" unless @coins;
note("coins built: ".scalar(@coins));

# ---------- 3. cross-sectional rank and signals ----------
{ my @m = sort { $a <=> $b } map { $_->{mom} } grep { defined $_->{mom} } @coins;
  for my $c (@coins) { next unless defined $c->{mom} && @m > 1; my $below = grep { $_ < $c->{mom} } @m; $c->{momp} = rd($below / (@m - 1) * 100, 0) } }
my ($btc) = grep { $_->{s} eq 'BTC' } @coins;
for my $c (@coins) {
  $c->{rs30} = rd($c->{r30} - $btc->{r30}, 1) if $btc && defined $c->{r30} && defined $btc->{r30};
  my @t;
  push @t, 'z3'  if defined $c->{z} && abs($c->{z}) >= 3;
  push @t, 'd10' if abs($c->{r24}) >= 10;
  push @t, 'w30' if defined $c->{r7} && abs($c->{r7}) >= 30;
  push @t, ($c->{brk} > 0 ? 'bo' : 'bd').abs($c->{brk}) if $c->{brk};
  push @t, 'vol' if defined $c->{volx} && $c->{volx} >= 2;
  push @t, 'crowd'   if defined $c->{momp} && $c->{momp} >= 80 && defined $c->{f7} && $c->{f7} >= 25;
  push @t, 'squeeze' if defined $c->{f7} && $c->{f7} <= -10 && defined $c->{r7} && $c->{r7} > 0;
  $c->{tags} = \@t;
  $c->{swing} = (grep { /^(z3|d10|w30)$/ } @t) ? ($c->{r24} >= 0 && (!defined $c->{r7} || abs($c->{r24}) >= 10 || (defined $c->{z} && abs($c->{z}) >= 3) ? 1 : ($c->{r7} >= 0 ? 1 : -1))) : 0;
  $c->{swing} = ($c->{r24} < 0 ? -1 : 1) if $c->{swing} && ((defined $c->{z} && abs($c->{z}) >= 3) || abs($c->{r24}) >= 10);
}

# ---------- 4. funding carry ----------
my @CARRY = qw(BTC ETH SOL); my %carry;
# data/carry_seed.json = funding history saved from a run that could reach every venue (fallback if a venue is unreachable)
my $SEED = js(slurp("data/carry_seed.json")); my $all_fresh = 1;
sub merge_daily { my ($coin, $venue, $acc) = @_;                       # $acc: date => summed rate (fraction)
  my %d; my $sd = $SEED ? $SEED->{$coin}{$venue} : undef; %d = %$sd if ref $sd eq "HASH";
  my $old = $prev && $prev->{carry}{$coin}{$venue} ? $prev->{carry}{$coin}{$venue}{daily} : undef; %d = (%d, %$old) if ref $old eq "HASH";
  my @k = sort keys %$acc; shift @k;                                    # first day of a fetch is partial
  for (@k) { next if $_ ge $TODAY; $d{$_} = rd($acc->{$_} * 1e4, 3) }    # stored in bps per day
  my @all = sort keys %d; splice(@all, 0, @all - 400) if @all > 400;
  return { map { $_ => $d{$_} } @all }, scalar(@k) }
sub day { strftime('%Y-%m-%d', gmtime($_[0] / 1000)) }
for my $coin (@CARRY) {
  my %src;
  { my (%a, $after); for my $pg (1..4) { my $d = okx("/api/v5/public/funding-rate-history?instId=$coin-USDT-SWAP&limit=100".($after ? "&after=$after" : '')); last unless $d && @$d;
      for (@$d) { $a{day($_->{fundingTime})} += (length($_->{realizedRate} // '') ? $_->{realizedRate} : $_->{fundingRate}) } $after = $d->[-1]{fundingTime}; last if @$d < 100; sleep(0.25) } $src{OKX} = \%a; }
  { my (%a); my $st = ($NOW - 366 * 86400) * 1000; for my $pg (1..30) { my $d = hl(qq({"type":"fundingHistory","coin":"$coin","startTime":$st})); last unless ref $d eq 'ARRAY' && @$d;
      $a{day($_->{time})} += $_->{fundingRate} for @$d; $st = $d->[-1]{time} + 1; last if @$d < 500; sleep(0.2) } $src{Hyperliquid} = \%a; }
  { my %a; my %KS = (BTC => 'PF_XBTUSD', ETH => 'PF_ETHUSD', SOL => 'PF_SOLUSD');                                                  # Kraken: one call returns the full hourly history
    my $d = js(curl("https://futures.kraken.com/derivatives/api/v4/historicalfundingrates?symbol=$KS{$coin}")); my $cut = strftime('%Y-%m-%d', gmtime($NOW - 400 * 86400));
    if (ref $d eq 'HASH' && ref $d->{rates} eq 'ARRAY') { for (@{$d->{rates}}) { my $dt = substr($_->{timestamp}, 0, 10); $a{$dt} += $_->{relativeFundingRate} if $dt ge $cut } } $src{Kraken} = \%a; }
  { my %a; my %DS = (BTC => 'BTC-PERPETUAL', ETH => 'ETH-PERPETUAL', SOL => 'SOL_USDC-PERPETUAL');                                  # Deribit: hourly, at most 744 rows a call, so 30-day windows
    for my $pg (0..12) { my ($e, $s) = (($NOW - $pg * 30 * 86400) * 1000, ($NOW - ($pg + 1) * 30 * 86400) * 1000 + 1);
      my $d = js(curl("https://www.deribit.com/api/v2/public/get_funding_rate_history?instrument_name=$DS{$coin}&start_timestamp=$s&end_timestamp=$e")); last unless ref $d eq 'HASH' && ref $d->{result} eq 'ARRAY' && @{$d->{result}};
      $a{day($_->{timestamp})} += $_->{interest_1h} for @{$d->{result}}; sleep(0.2) } $src{Deribit} = \%a; }
  for my $v (qw(OKX Hyperliquid Kraken Deribit)) {
    my ($daily, $fresh) = merge_daily($coin, $v, $src{$v}); my @k = sort keys %$daily; $all_fresh = 0 unless $fresh > 0; next unless @k;
    my %st; for my $w (7, 30, 90, 365) { my @x; for my $i (1..$w) { my $dt = strftime('%Y-%m-%d', gmtime($NOW - $i * 86400)); push @x, $daily->{$dt} if defined $daily->{$dt} }
      $st{"d$w"} = rd(mean(@x) * 365 / 100, 2) if @x >= .8 * $w; }
    my @v = map { $daily->{$_} } @k; $st{pos} = rd(100 * (grep { $_ > 0 } @v) / @v, 0); $st{n} = scalar @v; $st{last} = $k[-1]; $st{live} = $fresh > 0 ? 1 : 0;
    $carry{$coin}{$v} = { daily => $daily, st => \%st }; $all_fresh = 0 unless $fresh > 0;
    note(sprintf("carry %-3s %-11s days=%3d fresh=%3d  7d=%s 30d=%s 90d=%s 365d=%s", $coin, $v, scalar(@k), $fresh, map { $st{$_} // 'n/a' } qw(d7 d30 d90 d365)));
  }
}
if ($all_fresh && !$o{limit}) { make_path("data"); open my $sh, ">:raw", "data/carry_seed.json" or die $!; print $sh JSON::PP->new->utf8(1)->canonical(1)->encode({ map { my $c = $_; ($c => { map { ($_ => $carry{$c}{$_}{daily}) } keys %{$carry{$c}} }) } keys %carry }); close $sh; note("carry seed refreshed (all venues reachable)"); }
# hurdle: 13-week US T-bill yield
my $hurdle; { my $r = js(curl('https://query1.finance.yahoo.com/v8/finance/chart/%5EIRX?range=5d&interval=1d')); $hurdle = eval { $r->{chart}{result}[0]{meta}{regularMarketPrice} };
  $hurdle = $prev->{hurdle} if !$hurdle && $prev; note("3m T-bill: ".($hurdle // 'n/a')); }

# ---------- 5. write ----------
my $out = { gen => strftime('%d %b %Y %H:%M UTC', gmtime($NOW)), ts => $NOW, refresh_url => $ENV{REFRESH_URL} // '',
  coins => \@coins, carry => \%carry, hurdle => (defined $hurdle ? rd($hurdle, 2) : undef), log => \@log };
make_path($o{out});
my $json = JSON::PP->new->utf8(1)->canonical(1)->encode($out);
open my $h, '>:raw', "$o{out}/data.json" or die $!; print $h $json; close $h;
my $tpl = slurp('template.html'); (my $inl = $json) =~ s{</}{<\\/}g;
$tpl =~ s{(<script type="application/json" id="d-data">).*?(</script>)}{$1$inl$2}s or die "template has no d-data block\n";
open $h, '>:raw', "$o{out}/index.html" or die $!; print $h $tpl; close $h;
print "wrote $o{out}/index.html (".length($tpl)." bytes), $o{out}/data.json (".length($json)." bytes)\n";
