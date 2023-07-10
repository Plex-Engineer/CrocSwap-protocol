pragma solidity 0.8.19;

interface ICSRTurnstile {
    function register(address) external returns (uint256);
}
