var e=`/* https://developer.mozilla.org/docs/Web/HTTP/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_PAC_file */
/**
 * @param host The hostname from the URL (excluding port number).
 * @returns True if and only if there is no domain name in the hostname (no dots).
 */
declare function isPlainHostName(host: string): boolean;
/**
 * @param host The hostname from the URL.
 * @param domain The domain name to test the hostname against.
 * @returns True if and only if the domain of hostname matches.
 */
declare function dnsDomainIs(host: string, domain: string): boolean;
/**
 * @param host The hostname from the URL.
 * @param hostdom Fully qualified hostname to match against.
 * @returns True if the hostname matches exactly the specified hostname, or if there is no domain name part in the hostname, but the unqualified hostname matches.
 */
declare function localHostOrDomainIs(host: string, hostdom: string): boolean;
/**
 * @description Tries to resolve the hostname
 * @param host The hostname from the URL.
 * @returns True if succeeds.
 */
declare function isResolvable(host: string): boolean;
/**
 * @param host a DNS hostname, or IP address. If a hostname is passed, it will be resolved into an IP address by this function.
 * @param pattern an IP address pattern in the dot-separated format.
 * @param mask mask for the IP address pattern informing which parts of the IP address should be matched against. 0 means ignore, 255 means match.
 * @returns True if and only if the IP address of the host matches the specified IP address pattern.
 */
declare function isInNet(host: string, pattern: string, mask: string): boolean;
/**
 * @description Resolves the given DNS hostname into an IP address
 * @param host hostname to resolve.
 * @returns IP address in the dot-separated format as a string.
 */
declare function dnsResolve(host: string): string;
/**
 * @param ipaddr Any dotted address such as an IP address or mask.
 * @returns Concatenates the four dot-separated bytes into one 4-byte word and converts it to decimal.
 */
declare function convert_addr(ipaddr: string): number;
/**
 * @returns The server IP address of the machine Firefox is running on, as a string in the dot-separated integer format.It returns the same IP address as the server address returned by \`nslookup localhost\` on a Linux machine. It does not return the public IP address.
 */
declare function myIpAddress(): string;
/**
 * @param host The hostname from the URL.
 * @returns The number (integer) of DNS domain levels (number of dots) in the hostname.
 */
declare function dnsDomainLevels(host: string): number;
/**
 *
 * @param str Any string to compare (e.g. the URL, or the hostname).
 * @param shexp A shell expression to compare against.
 * @returns True if the string matches the specified shell glob expression.
 */
declare function shExpMatch(str: string, shexp: string): boolean;
declare type GMT = "GMT" | undefined;
declare type Month =
  | "JAN"
  | "FEB"
  | "MAR"
  | "APR"
  | "MAY"
  | "JUN"
  | "JUL"
  | "AUG"
  | "SEP"
  | "OCT"
  | "NOV"
  | "DEC";
declare type Day =
  | 1
  | 2
  | 3
  | 4
  | 5
  | 6
  | 7
  | 8
  | 9
  | 10
  | 11
  | 12
  | 13
  | 14
  | 15
  | 16
  | 17
  | 18
  | 19
  | 20
  | 21
  | 22
  | 23
  | 24
  | 25
  | 26
  | 27
  | 28
  | 29
  | 30
  | 31;
declare type Weekday = "SUN" | "MON" | "TUE" | "WED" | "THU" | "FRI" | "SAT";
declare type Hour =
  | 0
  | 1
  | 2
  | 3
  | 4
  | 5
  | 6
  | 7
  | 8
  | 9
  | 10
  | 11
  | 12
  | 13
  | 14
  | 15
  | 16
  | 17
  | 18
  | 19
  | 20
  | 21
  | 22
  | 23;
declare type MinuteOrSecond =
  | 0
  | 1
  | 2
  | 3
  | 4
  | 5
  | 6
  | 7
  | 8
  | 9
  | 10
  | 11
  | 12
  | 13
  | 14
  | 15
  | 16
  | 17
  | 18
  | 19
  | 20
  | 21
  | 22
  | 23
  | 24
  | 25
  | 26
  | 27
  | 28
  | 29
  | 30
  | 31
  | 32
  | 33
  | 34
  | 35
  | 36
  | 37
  | 38
  | 39
  | 40
  | 41
  | 42
  | 43
  | 44
  | 45
  | 46
  | 47
  | 48
  | 49
  | 50
  | 51
  | 52
  | 53
  | 54
  | 55
  | 56
  | 57
  | 58
  | 59;
/**
 * @param wd1 weekday string
 * @param wd2 weekday string
 * @param gmt Either the string "GMT" or is left out.
 * @returns True if the current weekday is in between those two ordered weekdays. Bounds are inclusive, but the bounds are ordered. If the "GMT" parameter is specified, times are taken to be in GMT. Otherwise, the local timezone is used.
 */
declare function weekdayRange(wd1: Weekday, wd2?: Weekday, gmt?: GMT): boolean;
/**
 * @param weekday weekday string
 * @param gmt Either the string "GMT" or is left out.
 * @returns True if the current weekday is the parameter represents. If the string "GMT" is specified as a second parameter, times are taken to be in GMT. Otherwise, they are assumed to be in the local timezone.
 */
declare function weekdayRange(weekday: Weekday, gmt?: GMT): boolean;
/**
 * @param day The ordered day of the month between 1 and 31 (as an integer).
 * @param gmt Either the string "GMT", which makes time comparison occur in GMT timezone, or is left out. If left unspecified, times are taken to be in the local timezone.
 */
declare function dateRange(day: Day, gmt?: GMT): boolean;
/**
 * @param month Month string
 * @param gmt Either the string "GMT", which makes time comparison occur in GMT timezone, or is left out. If left unspecified, times are taken to be in the local timezone.
 */
declare function dateRange(month: Month, gmt?: GMT): boolean;
/**
 * @param year The ordered full year integer number. For example, 2016 (not 16).
 * @param gmt Either the string "GMT", which makes time comparison occur in GMT timezone, or is left out. If left unspecified, times are taken to be in the local timezone.
 */
declare function dateRange(year: number, gmt?: GMT): boolean;
/**
 * @param month1 Month string
 * @param month2 Month string
 * @param gmt Either the string "GMT", which makes time comparison occur in GMT timezone, or is left out. If left unspecified, times are taken to be in the local timezone.
 */
declare function dateRange(month1: Month, month2: Month, gmt?: GMT): boolean;
/**
 * @param year1 The ordered full year integer number. For example, 2016 (not 16).
 * @param year2 The ordered full year integer number. For example, 2016 (not 16).
 * @param gmt Either the string "GMT", which makes time comparison occur in GMT timezone, or is left out. If left unspecified, times are taken to be in the local timezone.
 */
declare function dateRange(year1: number, year2: number, gmt?: GMT): boolean;
/**
 * @param day1 The ordered day of the month between 1 and 31 (as an integer).
 * @param month1 Month string
 * @param day2 The ordered day of the month between 1 and 31 (as an integer).
 * @param month2 Month string
 * @param gmt Either the string "GMT", which makes time comparison occur in GMT timezone, or is left out. If left unspecified, times are taken to be in the local timezone.
 */
declare function dateRange(
  day1: Day,
  month1: Month,
  day2: Day,
  month2: Month,
  gmt?: GMT,
): boolean;
/**
 * @param day The ordered day of the month between 1 and 31 (as an integer).
 * @param month Month string
 * @param gmt Either the string "GMT", which makes time comparison occur in GMT timezone, or is left out. If left unspecified, times are taken to be in the local timezone.
 */
declare function dateRange(day: Day, month: Month, gmt?: GMT): boolean;
/**
 * @param month1 Month string
 * @param year1 The ordered full year integer number. For example, 2016 (not 16).
 * @param month2 Month string
 * @param year2 The ordered full year integer number. For example, 2016 (not 16).
 * @param gmt Either the string "GMT", which makes time comparison occur in GMT timezone, or is left out. If left unspecified, times are taken to be in the local timezone.
 */
declare function dateRange(
  month1: Month,
  year1: number,
  month2: Month,
  year2: number,
  gmt?: GMT,
): boolean;
/**
 * @param day1 The ordered day of the month between 1 and 31 (as an integer).
 * @param month1 Month string
 * @param year1 The ordered full year integer number. For example, 2016 (not 16).
 * @param day2 The ordered day of the month between 1 and 31 (as an integer).
 * @param month2 Month string
 * @param year2 The ordered full year integer number. For example, 2016 (not 16).
 * @param gmt Either the string "GMT", which makes time comparison occur in GMT timezone, or is left out. If left unspecified, times are taken to be in the local timezone.
 */
declare function dateRange(
  day1: Day,
  month1: Month,
  year1: number,
  day2: Day,
  month2: Month,
  year2: number,
  gmt?: GMT,
): boolean;
/**
 * @param hour The hour from 0 to 23. (0 is midnight, 23 is 11 pm.)
 * @param gmt Either the string "GMT" for GMT timezone, or not specified, for local timezone.
 * @returns True if at times that match that specification
 */
declare function timerange(hour: Hour, gmt?: GMT): boolean;
/**
 * @param hour The hour from 0 to 23. (0 is midnight, 23 is 11 pm.)
 * @param minute Minutes from 0 to 59.
 * @param gmt Either the string "GMT" for GMT timezone, or not specified, for local timezone.
 * @returns True if at times that match that specification
 */
declare function timerange(
  hour: Hour,
  minute: MinuteOrSecond,
  gmt?: GMT,
): boolean;
/**
 * @param hour1 The hour from 0 to 23. (0 is midnight, 23 is 11 pm.)
 * @param minute1 Minutes from 0 to 59.
 * @param hour2 The hour from 0 to 23. (0 is midnight, 23 is 11 pm.)
 * @param minute2 Minutes from 0 to 59.
 * @param gmt Either the string "GMT" for GMT timezone, or not specified, for local timezone.
 * @returns True if between those times, including bounds, but the bounds are ordered.
 */
declare function timerange(
  hour1: Hour,
  minute1: MinuteOrSecond,
  hour2: Hour,
  minute2: MinuteOrSecond,
  gmt?: GMT,
): boolean;
/**
 * @param hour1 The hour from 0 to 23. (0 is midnight, 23 is 11 pm.)
 * @param minute1 Minutes from 0 to 59.
 * @param second1 Seconds from 0 to 59.
 * @param hour2 The hour from 0 to 23. (0 is midnight, 23 is 11 pm.)
 * @param minute2 Minutes from 0 to 59.
 * @param second2 Seconds from 0 to 59.
 * @param gmt Either the string "GMT" for GMT timezone, or not specified, for local timezone.
 * @returns True if between those times, including bounds, but the bounds are ordered.
 */
declare function timerange(
  hour1: Hour,
  minute1: MinuteOrSecond,
  second1: MinuteOrSecond,
  hour2: Hour,
  minute2: MinuteOrSecond,
  second2: MinuteOrSecond,
  gmt?: GMT,
): boolean;
/**
 * @param message The string to log
 */
declare function alert(message: string): void;
`;export{e as default};