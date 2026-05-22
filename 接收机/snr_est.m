function y = snr_est(rx_sig)
%信噪比估计模块
rx_sig=abs(real(rx_sig))+1i*abs(imag(rx_sig));%全部转到第1象限
y=(abs(mean(rx_sig))^2)/var(rx_sig);
end