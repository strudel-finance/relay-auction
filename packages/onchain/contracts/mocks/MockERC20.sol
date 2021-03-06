pragma solidity 0.6.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
  bytes32 public DOMAIN_SEPARATOR;
  // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
  bytes32
    public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
  mapping(address => uint256) public nonces;

  constructor(uint256 supply) public ERC20("name", "SYM") {
    uint256 chainId;
    assembly {
      chainId := chainid()
    }
    DOMAIN_SEPARATOR = keccak256(
      abi.encode(
        keccak256(
          "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        ),
        keccak256(bytes("name")),
        keccak256(bytes("1")),
        chainId,
        address(this)
      )
    );
    _mint(msg.sender, supply);
  }

  function burn(uint256 _amount) external {
    _burn(msg.sender, _amount);
  }

  function mint(address _recipient, uint256 _amount) public returns (bool) {
    _mint(_recipient, _amount);
  }

  function permit(
    address owner,
    address spender,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external {
    require(deadline >= block.timestamp, "Strudel: EXPIRED");
    bytes32 digest = keccak256(
      abi.encodePacked(
        "\x19\x01",
        DOMAIN_SEPARATOR,
        keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
      )
    );
    address recoveredAddress = ecrecover(digest, v, r, s);
    require(
      recoveredAddress != address(0) && recoveredAddress == owner,
      "Strudel: INVALID_SIGNATURE"
    );
    _approve(owner, spender, value);
  }
}
