module leizd::permission {
  const E_NOT_OWNER: u64 = 1;

  public fun owner_address(): address {
    @leizd
  }

  public fun is_owner(account: address): bool {
    account == owner_address()
  }

  public fun assert_owner(account: address) {
    assert!(is_owner(account), E_NOT_OWNER);
  }
}