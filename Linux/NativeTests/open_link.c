// Which links the app opens in the browser: only WellSpent's own pages.
#include "wellspent_native.h"
#include <gtk/gtk.h>

static int failures;

static void expect(int ok, const char *what) {
    if (ok) return;
    failures++;
    g_printerr("open link: %s\n", what);
}

int main(void) {
    expect(wellspent_link_is_ours("https://wellspent.space/checkout?tier=starter"), "checkout on the site");
    expect(wellspent_link_is_ours("https://staging.wellspent.space/plans"), "a part of the site");
    expect(wellspent_link_is_ours("https://WellSpent.Space/"), "the name in any case");
    expect(!wellspent_link_is_ours("http://wellspent.space/"), "plain http is refused");
    expect(!wellspent_link_is_ours("https://wellspent.space.example.com/"), "a look-alike host is refused");
    expect(!wellspent_link_is_ours("https://evilwellspent.space/"), "a host that only ends the same is refused");
    expect(!wellspent_link_is_ours("https://user:secret@wellspent.space/"), "a user name is refused");
    expect(!wellspent_link_is_ours("https://wellspent.space:8443/"), "a port is refused");
    // A browser reads a backslash as a slash, so these open evil.com.
    expect(!wellspent_link_is_ours("https://evil.com\\.wellspent.space/"), "a backslash in the host is refused");
    expect(!wellspent_link_is_ours("https://evil.com%5C.wellspent.space/"), "an escaped backslash is refused");
    expect(!wellspent_link_is_ours("https://evil.com%2F.wellspent.space/"), "an escaped slash is refused");
    expect(!wellspent_link_is_ours("https://evil.com%23.wellspent.space/"), "an escaped # is refused");
    expect(!wellspent_link_is_ours("file:///etc/passwd"), "a file is refused");
    expect(!wellspent_link_is_ours("javascript:alert(1)"), "script is refused");
    expect(!wellspent_link_is_ours(""), "nothing is refused");
    expect(!wellspent_link_is_ours(NULL), "no link is refused");
    expect(wellspent_link_is_ours("mailto:dev@wellspent.space?subject=More%20than%2015%20properties"),
           "mail to us with a subject");
    expect(wellspent_link_is_ours("mailto:dev@wellspent.space"), "mail to us");
    expect(!wellspent_link_is_ours("mailto:someone@example.com"), "mail to someone else is refused");
    expect(!wellspent_link_is_ours("mailto:dev@wellspent.space.example.com"), "a look-alike address is refused");
    expect(!wellspent_link_is_ours("mailto:dev@wellspent.space,x@example.com"), "a second recipient is refused");
    expect(!wellspent_link_is_ours("mailto:x%40example.com%2Cdev@wellspent.space"), "an escaped second one too");
    expect(!wellspent_link_is_ours("mailto:dev@wellspent.space?cc=x@example.com"), "a copy to someone is refused");
    expect(!wellspent_link_is_ours("mailto:dev@wellspent.space?subject=a&bcc=x@example.com"), "so is a blind copy");
    expect(!wellspent_link_is_ours("mailto:@wellspent.space"), "an address with no name is refused");
    expect(!wellspent_open_link("https://example.com/"), "opening someone else's page is refused");
    if (failures) g_printerr("open link: %d check(s) failed\n", failures);
    else g_print("open link: ok\n");
    return failures ? 1 : 0;
}
