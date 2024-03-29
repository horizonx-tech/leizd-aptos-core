module leizd_aptos_common::permission {
  use std::error;
  use std::signer;
  use std::acl;

  // signer is not owner
  const ENOT_OWNER: u64 = 1;
  // owner cannot be removed
  const ECANNOT_BE_REMOVED_OWNER: u64 = 2;
  // signer is neither operator nor owner
  const ENOT_OPERATOR: u64 = 3;
  // signer is neither configurator nor owner
  const ENOT_CONFIGURATOR: u64 = 4;

  struct Roles has key {
    operators: acl::ACL,
    configurators: acl::ACL,
  }

  public entry fun initialize(owner: &signer) {
    initialize_internal(owner);
  }

  fun initialize_internal(owner: &signer) {
    let owner_address = signer::address_of(owner);
    assert_owner(owner_address);

    let configurators = acl::empty();
    let operators = acl::empty();
    acl::add(&mut configurators, owner_address);
    acl::add(&mut operators, owner_address);

    move_to(owner, Roles {configurators, operators});
  }

  // owner
  public fun owner_address(): address {
    @leizd_aptos_common
  }

  public fun is_owner(account: address): bool {
    account == owner_address()
  }

  public fun assert_owner(account: address) {
    assert!(is_owner(account),error::invalid_argument(ENOT_OWNER));
  }

  // configurators
  public fun configurators(): acl::ACL acquires Roles {
    borrow_global<Roles>(owner_address()).configurators
  }

  public entry fun add_configurators(owner: &signer, new_addr: address) acquires Roles {
    let owner_address = signer::address_of(owner);
    assert_owner(owner_address);
    let roles_ref = borrow_global_mut<Roles>(owner_address);
    acl::add(&mut roles_ref.configurators, new_addr);
  }

  public entry fun remove_configurators(owner: &signer, removed_addr: address) acquires Roles {
    assert!(!is_owner(removed_addr),error::invalid_argument(ECANNOT_BE_REMOVED_OWNER));
    let owner_address = signer::address_of(owner);
    assert_owner(owner_address);
    let roles_ref = borrow_global_mut<Roles>(owner_address);
    acl::remove(&mut roles_ref.configurators, removed_addr);
  }

  public fun contains_configurators(account: address): bool acquires Roles {
    acl::contains(&configurators(), account)
  }

  public fun assert_configurator(account: address) acquires Roles {
    assert!(contains_configurators(account),error::invalid_argument(ENOT_CONFIGURATOR));
  }

  // operator
  public fun operators(): acl::ACL acquires Roles {
    borrow_global<Roles>(owner_address()).operators
  }

  public entry fun add_operators(owner: &signer, new_addr: address) acquires Roles {
    let owner_address = signer::address_of(owner);
    assert_owner(owner_address);
    let roles_ref = borrow_global_mut<Roles>(owner_address);
    acl::add(&mut roles_ref.operators, new_addr);
  }

  public entry fun remove_operators(owner: &signer, removed_addr: address) acquires Roles {
    assert!(!is_owner(removed_addr),error::invalid_argument(ECANNOT_BE_REMOVED_OWNER));
    let owner_address = signer::address_of(owner);
    assert_owner(owner_address);
    let roles_ref = borrow_global_mut<Roles>(owner_address);
    acl::remove(&mut roles_ref.operators, removed_addr);
  }

  public fun contains_operators(account: address): bool acquires Roles {
    acl::contains(&operators(), account)
  }

  public fun assert_operator(account: address) acquires Roles {
    assert!(contains_operators(account),error::invalid_argument(ENOT_OPERATOR));
  }

  #[test(owner = @leizd_aptos_common, account = @0x111)]
  fun test_add_configurator(owner: &signer, account: address) acquires Roles {
    initialize(owner);
    assert!(!contains_configurators(account), 0);
    add_configurators(owner, account);
    assert_configurator(account);
  }

  #[test(owner = @leizd_aptos_common, account = @0x111)]
  fun test_remove_configurator(owner: &signer, account: address) acquires Roles {
    initialize(owner);
    assert!(!contains_configurators(account), 0);
    add_configurators(owner, account);
    assert_configurator(account);
    remove_configurators(owner, account);
    assert!(!contains_configurators(account), 0);
  }

  #[test(owner = @leizd_aptos_common, account = @0x111)]
  fun test_add_operator(owner: &signer, account: address) acquires Roles {
    initialize(owner);
    assert!(!contains_operators(account), 0);
    add_operators(owner, account);
    assert_operator(account);
  }

  #[test(owner = @leizd_aptos_common, account = @0x111)]
  fun test_remove_operator(owner: &signer, account: address) acquires Roles {
    initialize(owner);
    assert!(!contains_operators(account), 0);
    add_operators(owner, account);
    assert_operator(account);
    remove_operators(owner, account);
    assert!(!contains_operators(account), 0);
  }

  #[test(owner = @leizd_aptos_common)]
  #[expected_failure(abort_code = 65538)]
  fun test_remove_owner_from_configurator(owner: &signer) acquires Roles {
    let owner_addr = signer::address_of(owner);
    initialize(owner);
    assert_configurator(owner_addr);
    remove_configurators(owner, owner_addr);
  }

  #[test(owner = @leizd_aptos_common)]
  #[expected_failure(abort_code = 65538)]
  fun test_remove_owner_from_operator(owner: &signer) acquires Roles {
    let owner_addr = signer::address_of(owner);
    initialize(owner);
    assert_operator(owner_addr);
    remove_operators(owner, owner_addr);
  }
}