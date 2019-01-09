import { default as computed } from "ember-addons/ember-computed-decorators";

export default Ember.Controller.extend({
  application: Ember.inject.controller(),

  @computed("siteSettings.email_in", "model.automatic", "currentUser.admin")
  tabs(emailIn, automatic, isAdmin) {
    const defaultTabs = [];

    defaultTabs.push({
      route: "group.manage.interaction",
      title: "groups.manage.interaction.title"
    });

    if (emailIn && isAdmin && !automatic) {
      defaultTabs.push({
        route: "group.manage.email",
        title: "groups.manage.email.title"
      });
    }

    defaultTabs.push({
      route: "group.manage.logs",
      title: "groups.manage.logs.title"
    });

    if (!automatic) {
      defaultTabs.splice(0, 0, {
        route: "group.manage.profile",
        title: "groups.manage.profile.title"
      });

      defaultTabs.splice(1, 0, {
        route: "group.manage.membership",
        title: "groups.manage.membership.title"
      });
    }

    return defaultTabs;
  }
});
