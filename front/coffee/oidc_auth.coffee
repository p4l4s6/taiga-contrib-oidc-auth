module = angular.module('taigaContrib.oidcAuth', [])

OIDCLoginButtonDirective = ($window, $params, $location, $config, $events, $confirm, $auth, $navUrls, $loader, $rootScope) ->
    # Login or register a user with their OIDC account.

    link = ($scope, $el, $attrs) ->

        loginSuccess = ->
            # Login in the UI. Using $auth.login() is too GitHub-specific.
            $auth.removeToken();
            data = _.clone($params, false);
            user = $auth.model.make_model("users", data);
            $auth.setToken(user.auth_token);
            $auth.setUser(user);
            $rootScope.$broadcast("auth:login", user)

            # Cleanup the URL

            $events.setupConnection()  # I don't know why this is necessary.

            scrub = (name, i) ->
                $location.search(name, null)
             [
                'accepted_terms', 'auth_token', 'big_photo', 'bio', 'color', 'date_joined',
                'email', 'full_name', 'full_name_display', 'gravatar_id', 'id', 'is_active',
                'lang', 'max_memberships_private_projects', 'max_memberships_public_projects',
                'max_private_projects', 'max_public_projects', 'next', 'photo', 'read_new_terms',
                'roles', 'theme', 'timezone', 'total_private_projects', 'total_public_projects',
                'type', 'username', 'uuid'
            ].forEach(scrub)

            # Redirect to the destination page.

            if $params.next and $params.next != $navUrls.resolve("login")
                nextUrl = $params.next
            else
                nextUrl = $navUrls.resolve("home")

            $location.path(nextUrl)

        loginError = ->
            error_description = $params.error_description

            $location.search("type", null)
            $location.search("error", null)
            $location.search("error_description", null)

            if error_description
                $confirm.notify("light-error", error_description)
            else
                $confirm.notify("light-error", "Our Oompa Loompas have not been able to get you
                                                credentials from GitHub.")  #TODO: i18n

        loginWithOIDCAccount = ->
            type = $params.type
            auth_token = $params.auth_token

            return if not (type == "oidc")

            if $params.error
                loginError()
            else
                loginSuccess()

        loginWithOIDCAccount()

        $el.on "click", ".button-auth", (event) ->
            if $params.next and $params.next != $navUrls.resolve("login")
                nextUrl = $params.next
            else
                nextUrl = $navUrls.resolve("home")
            base_url = $config.get("api", "/api/v1/").split('/').slice(0, -3).join("/")
            url = urljoin(
                base_url,
                $config.get("oidcMountPoint", "/oidc"),
                "authenticate/"
            )
            url += "?next=" + nextUrl
            $window.location.href = url

        $scope.$on "$destroy", ->
            $el.off()

        # Template context
        $scope.buttonText = $config.get("oidcButtonText", "Login with Microsoft")
        $scope.buttonImage = $config.get("oidcButtonImage", "logo.gif")

    return {
        link: link
        restrict: "EA"
        template: ""
    }

module.directive("tgOidcLoginButton", [
   "$window", '$routeParams', "$tgLocation", "$tgConfig", "$tgEvents",
   "$tgConfirm", "$tgAuth", "$tgNavUrls", "tgLoader", "$rootScope",
   OIDCLoginButtonDirective])


#############################################################################
## Hide "change password" in account settings for SSO-only deployments
#############################################################################
#
# When this Taiga instance has local username/password login disabled
# (conf.json's "defaultLoginEnabled": false - the same flag the core login
# page already reads, see coffee/modules/auth.coffee in taiga-front), every
# real account authenticates via OIDC and has no usable local password to
# change. We hide the "Change password" option in that case.
#
# This is implemented as an overlay on top of stock taiga-front, using
# Angular's $provide.decorator on the two core directives involved, rather
# than forking/rebuilding taiga-front itself:
#   - tgUserSettingsNavigation: renders the account settings sidebar menu
#     (shown on every settings page) - we remove the "Change password" link.
#   - tgUserChangePassword: wraps the change-password form itself - we
#     replace its contents with an explanatory notice and skip wiring up
#     the submit handler, so the form can't be reached even by direct URL.
#
# This overlay technique is proven to load before Angular bootstrap (it's
# the same mechanism that renders the OIDC login button above), so decorating
# core directives from here reaches the whole app, not just this plugin's
# own template.
#
# IMPORTANT Angular gotcha (this is why the first version of this overlay
# silently did nothing, even though it registered without error and even
# though `$injector.get("tgUserChangePasswordDirective")[0].link` correctly
# showed the new function):
#
# Neither tgUserSettingsNavigation nor tgUserChangePassword define a
# `compile` function in taiga-front's stock source - only `link`. The very
# first time Angular resolves a `.directive(name, factory)` provider (i.e.
# the first `$injector.get(name + "Directive")` call, which happens lazily,
# either from our own decorator's `$delegate` resolution or from $compile
# itself, whichever runs first), Angular's own internal directive factory
# normalizes the returned definition object by doing roughly:
#     if (!directive.compile && directive.link) {
#         directive.compile = valueFn(directive.link)
#     }
# That synthesized `directive.compile` is a closure that always returns the
# *original* link function it captured at that moment - it does not re-read
# `directive.link` later. $compile prefers `directive.compile` over
# `directive.link` whenever both are present. So simply reassigning
# `directive.link` (as this overlay used to do) changes a property Angular's
# compiler no longer looks at once `.compile` exists; the original link
# function keeps running unmodified, with no error anywhere to signal it.
#
# The fix is to overwrite `directive.compile` too (not just `directive.link`)
# so it returns our replacement link function instead of the stale one.

decorateDirectiveLink = (directive, newLink) ->
    directive.link = newLink
    directive.compile = -> newLink

HideChangePasswordNavDecorator = ($delegate, $tgConfig) ->
    directive = $delegate[0]
    originalLink = directive.link
    newLink = ($scope, $el, $attrs) ->
        originalLink($scope, $el, $attrs)
        if not $tgConfig.get("defaultLoginEnabled", true)
            $el.find("#usersettingsmenu-change-password").remove()
    decorateDirectiveLink(directive, newLink)
    return $delegate

HideChangePasswordFormDecorator = ($delegate, $tgConfig) ->
    directive = $delegate[0]
    originalLink = directive.link
    newLink = ($scope, $el, $attrs, $ctrl) ->
        if not $tgConfig.get("defaultLoginEnabled", true)
            $el.find("section.main.user-change-password").html(
                "<header><h1>Change Password</h1></header>" +
                "<p>Password login is disabled for this account because " +
                "single sign-on (SSO) is required. Contact your " +
                "administrator if you believe this is incorrect.</p>"
            )
            return
        originalLink($scope, $el, $attrs, $ctrl)
    decorateDirectiveLink(directive, newLink)
    return $delegate

HideChangePasswordConfig = ($provide) ->
    $provide.decorator("tgUserSettingsNavigationDirective", [
        "$delegate", "$tgConfig", HideChangePasswordNavDecorator])
    $provide.decorator("tgUserChangePasswordDirective", [
        "$delegate", "$tgConfig", HideChangePasswordFormDecorator])

module.config(["$provide", HideChangePasswordConfig])
