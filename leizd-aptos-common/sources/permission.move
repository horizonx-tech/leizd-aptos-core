module leizd_aptos_common::permission {
  const E_NOT_OWNER: u64 = 1;

  public fun owner_address(): address {
    @leizd_aptos_common
  }

  public fun is_owner(account: address): bool {
    account == owner_address()
  }

  public fun assert_owner(account: address) {
    assert!(is_owner(account), E_NOT_OWNER);
  }
}